//! Fixed-allowlist Boris process orchestration.
//!
//! The runner owns process control and artifact adaptation only. It never
//! parses source, infers graph meaning, or accepts arbitrary argv from the UI.

const std = @import("std");
const Io = std.Io;
const contracts = @import("contracts.zig");
const diagnostic_packet = @import("diagnostic_packet.zig");
const project = @import("project.zig");

pub const Mode = enum {
    validate,
    ir_build,
    html_build,
    check,
    impact,
    plan,
    recipe_scale,
};

pub const FailureClass = enum {
    success,
    content,
    usage,
    io,
    terminated,
};

pub const Origin = enum {
    build_report,
    analysis_report,
    stderr,
    process,
};

pub const PositionConfidence = enum {
    exact,
    best_effort,
    none,
};

pub const Problem = struct {
    severity: contracts.Severity,
    code: ?[]const u8,
    message: []const u8,
    remediation: []const u8,
    source_path: ?[]const u8,
    line: ?u32,
    column: ?u32,
    id: ?[]const u8,
    origin: Origin,
    position_confidence: PositionConfidence,
    packet: []const u8,
};

pub const Finding = struct {
    code: []const u8,
    endpoint_type: contracts.EndpointType,
    value: []const u8,
    count: u32,
    source_path: ?[]const u8,
    line: ?u32,
    column: ?u32,
};

pub const ImpactEndpoint = struct {
    endpoint_type: contracts.EndpointType,
    value: []const u8,
};

pub const Result = struct {
    mode: Mode,
    exit_code: ?u8,
    failure_class: FailureClass,
    compiler_id: []const u8,
    report_version: ?[]const u8,
    used_stderr_fallback: bool,
    problems: []Problem,
    findings: []Finding,
    impact: []ImpactEndpoint,
    publication_plan: ?std.json.Value = null,
    recipe_scale_view: ?std.json.Value = null,
};

pub const Config = struct {
    project_root: []const u8,
    boris_path: []const u8,
    editor_id: []const u8,
};

pub const Request = struct {
    mode: Mode,
    impact_id: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    recipe_scale_id: ?[]const u8 = null,
    recipe_scale_factor: ?[]const u8 = null,
};

const check_report_name = "editor-check.json";
const impact_report_name = "editor-impact.json";
pub const html_report_name = "html-build-report.json";
const max_process_output = 16 * 1024 * 1024;
const max_report_bytes = 32 * 1024 * 1024;

/// Allocations in the returned result belong to `allocator`. Callers normally
/// pass a request-scoped arena and release the arena after JSON serialization.
pub fn run(allocator: std.mem.Allocator, io: Io, config: Config, request: Request) !Result {
    if (request.mode == .impact) try validateImpactId(request.impact_id orelse return error.ImpactIdRequired);
    if (request.mode != .impact and request.impact_id != null) return error.UnexpectedImpactId;
    if (request.mode == .plan) try validateProfilePath(request.profile orelse return error.ProfileRequired);
    if (request.mode != .plan and request.profile != null) return error.UnexpectedProfile;
    if (request.mode == .recipe_scale) {
        try validateRecipeScaleId(request.recipe_scale_id orelse return error.RecipeScaleIdRequired);
        try validateRecipeScaleFactor(request.recipe_scale_factor orelse return error.RecipeScaleFactorRequired);
    }
    if (request.mode != .recipe_scale and (request.recipe_scale_id != null or request.recipe_scale_factor != null)) {
        return error.UnexpectedRecipeScale;
    }
    try prepareArtifactRoot(io, config.project_root, request.mode);

    const compiler_id = try readCompilerId(allocator, io, config);
    const execution = execute(allocator, io, config, request) catch |err| switch (err) {
        error.Timeout => return processFailureResult(allocator, config, request.mode, compiler_id, .terminated, null, "Boris did not finish before the command timeout."),
        error.StreamTooLong => return processFailureResult(allocator, config, request.mode, compiler_id, .terminated, null, "Boris exceeded the bounded process-output limit."),
        else => |other| return other,
    };
    const exit_code = termExitCode(execution.term);
    const failure_class = classifyTerm(execution.term);

    var problems: std.ArrayList(Problem) = .empty;
    var findings: std.ArrayList(Finding) = .empty;
    var impact: std.ArrayList(ImpactEndpoint) = .empty;
    var report_version: ?[]const u8 = null;
    var structured_report = false;
    var publication_plan: ?std.json.Value = null;
    var recipe_scale_view: ?std.json.Value = null;

    switch (request.mode) {
        .ir_build => if (try readGeneratedFile(allocator, io, config.project_root, "build-report.json")) |bytes| {
            var document = contracts.readBuildReport(allocator, bytes) catch return error.UnsupportedArtifact;
            defer document.deinit();
            report_version = try allocator.dupe(u8, document.version);
            try appendStructuredProblems(allocator, config, request.mode, compiler_id, failure_class, &document, .build_report, &problems);
            structured_report = true;
        },
        .check => if (try readGeneratedFile(allocator, io, config.project_root, check_report_name)) |bytes| {
            var document = contracts.readDocumentationIntelligence(allocator, bytes) catch return error.UnsupportedArtifact;
            defer document.deinit();
            report_version = try allocator.dupe(u8, document.version);
            try appendStructuredProblems(allocator, config, request.mode, compiler_id, failure_class, &document, .analysis_report, &problems);
            try appendFindings(allocator, config.project_root, &document, &findings);
            structured_report = true;
        },
        .impact => if (try readGeneratedFile(allocator, io, config.project_root, impact_report_name)) |bytes| {
            var document = contracts.readDocumentationIntelligence(allocator, bytes) catch return error.UnsupportedArtifact;
            defer document.deinit();
            report_version = try allocator.dupe(u8, document.version);
            try appendStructuredProblems(allocator, config, request.mode, compiler_id, failure_class, &document, .analysis_report, &problems);
            try appendFindings(allocator, config.project_root, &document, &findings);
            try appendImpact(allocator, config.project_root, &document, &impact);
            structured_report = true;
        },
        .validate, .html_build => if (try readGeneratedFile(allocator, io, config.project_root, html_report_name)) |bytes| {
            var document = contracts.readHtmlBuildReport(allocator, bytes) catch return error.UnsupportedArtifact;
            defer document.deinit();
            report_version = try allocator.dupe(u8, document.version);
            try appendStructuredProblems(allocator, config, request.mode, compiler_id, failure_class, &document, .build_report, &problems);
            structured_report = true;
        },
        .plan => if (failure_class == .success) {
            const document = contracts.readPublicationPlan(allocator, execution.stdout) catch return error.UnsupportedArtifact;
            report_version = try allocator.dupe(u8, document.version);
            publication_plan = document.parsed.value;
            structured_report = true;
        },
        .recipe_scale => if (failure_class == .success) {
            recipe_scale_view = try parseRecipeScaleView(allocator, execution.stdout);
            structured_report = true;
        },
    }

    if (!structured_report or problems.items.len == 0) {
        try appendStderrProblems(allocator, config, request.mode, compiler_id, failure_class, execution.stderr, &problems);
    }
    if (failure_class != .success and problems.items.len == 0) {
        try appendProcessProblem(allocator, config, request.mode, compiler_id, failure_class, fallbackFailureMessage(failure_class), &problems);
    }

    return .{
        .mode = request.mode,
        .exit_code = exit_code,
        .failure_class = failure_class,
        .compiler_id = compiler_id,
        .report_version = report_version,
        .used_stderr_fallback = !structured_report,
        .problems = try problems.toOwnedSlice(allocator),
        .findings = try findings.toOwnedSlice(allocator),
        .impact = try impact.toOwnedSlice(allocator),
        .publication_plan = publication_plan,
        .recipe_scale_view = recipe_scale_view,
    };
}

fn execute(allocator: std.mem.Allocator, io: Io, config: Config, request: Request) !std.process.RunResult {
    const discovered = project.discover(io, config.project_root) catch project.Discovery{
        .content = false,
        .default_layout = false,
        .publication_profile = false,
        .input_mode = .empty,
    };
    const argv = try commandArgv(allocator, config.boris_path, request, discovered.input_mode);
    defer allocator.free(argv);
    return std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = config.project_root },
        .stdout_limit = .limited(max_process_output),
        .stderr_limit = .limited(max_process_output),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(120) } },
    });
}

pub fn commandArgv(
    allocator: std.mem.Allocator,
    boris_path: []const u8,
    request: Request,
    input_mode: project.InputMode,
) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.append(allocator, boris_path);
    switch (request.mode) {
        .validate => try args.appendSlice(allocator, &.{ "validate", "--input", "content", "--report", ".boris/" ++ html_report_name }),
        .ir_build => try args.appendSlice(allocator, &.{ "build", "--input", "content", "--out", ".boris" }),
        .html_build => try args.appendSlice(allocator, &.{ "build", "--input", "content", "--html-dir", "dist", "--report", ".boris/" ++ html_report_name }),
        .check => try args.appendSlice(allocator, &.{ "check", "--input", "content", "--format", "json", "--report", ".boris/" ++ check_report_name }),
        .impact => try args.appendSlice(allocator, &.{ "impact", request.impact_id.?, "--input", "content", "--format", "json", "--report", ".boris/" ++ impact_report_name }),
        .plan => try args.appendSlice(allocator, &.{ "plan", "--profile", request.profile.? }),
        .recipe_scale => try args.appendSlice(allocator, &.{
            "recipe-scale",
            "--input",
            "content",
            "--id",
            request.recipe_scale_id.?,
            "--factor",
            request.recipe_scale_factor.?,
        }),
    }
    if (input_mode == .cooklang and request.mode != .plan) try args.append(allocator, "--cooklang");
    return args.toOwnedSlice(allocator);
}

fn readCompilerId(allocator: std.mem.Allocator, io: Io, config: Config) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ config.boris_path, "--version" },
        .cwd = .{ .path = config.project_root },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    }) catch return error.BorisUnavailable;
    const code = termExitCode(result.term) orelse return error.BorisUnavailable;
    const compiler_id = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (code != 0 or compiler_id.len == 0 or !std.mem.startsWith(u8, compiler_id, "boris/") or std.mem.indexOfAny(u8, compiler_id, "\r\n") != null) {
        return error.InvalidBorisVersion;
    }
    return allocator.dupe(u8, compiler_id);
}

fn prepareArtifactRoot(io: Io, project_root: []const u8, mode: Mode) !void {
    if (mode != .ir_build and mode != .check and mode != .impact and mode != .validate and mode != .html_build) return;
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    var artifact_dir = root.openDir(io, ".boris", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (mode == .ir_build) return;
            try root.createDir(io, ".boris", .default_dir);
            break :blk try root.openDir(io, ".boris", .{ .follow_symlinks = false });
        },
        else => |other| return other,
    };
    defer artifact_dir.close(io);
    const stale_name = switch (mode) {
        .ir_build => "build-report.json",
        .check => check_report_name,
        .impact => impact_report_name,
        .validate, .html_build => html_report_name,
        .plan, .recipe_scale => unreachable,
    };
    artifact_dir.deleteFile(io, stale_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |other| return other,
    };
}

fn readGeneratedFile(allocator: std.mem.Allocator, io: Io, project_root: []const u8, name: []const u8) !?[]u8 {
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    var artifact_dir = root.openDir(io, ".boris", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer artifact_dir.close(io);
    var file = artifact_dir.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsafeArtifact;
    var reader = file.reader(io, &.{});
    const bytes = try reader.interface.allocRemaining(allocator, .limited(max_report_bytes));
    return bytes;
}

fn appendStructuredProblems(
    allocator: std.mem.Allocator,
    config: Config,
    mode: Mode,
    compiler_id: []const u8,
    failure_class: FailureClass,
    document: *const contracts.Document,
    origin: Origin,
    problems: *std.ArrayList(Problem),
) !void {
    const diagnostics = contracts.extractDiagnostics(allocator, document) catch return error.UnsupportedArtifact;
    defer allocator.free(diagnostics);
    for (diagnostics) |diagnostic| {
        const source_path = try copySourcePath(allocator, diagnostic.source_path);
        const confidence = structuredConfidence(source_path, diagnostic.code, diagnostic.line, diagnostic.column);
        try appendProblem(allocator, config, mode, compiler_id, failure_class, problems, .{
            .severity = diagnostic.severity,
            .code = diagnostic.code,
            .message = diagnostic.message,
            .remediation = diagnostic.remediation,
            .source_path = source_path,
            .line = diagnostic.line,
            .column = diagnostic.column,
            .id = diagnostic.id,
            .origin = origin,
            .position_confidence = confidence,
        });
    }
}

fn appendStderrProblems(
    allocator: std.mem.Allocator,
    config: Config,
    mode: Mode,
    compiler_id: []const u8,
    failure_class: FailureClass,
    stderr: []const u8,
    problems: *std.ArrayList(Problem),
) !void {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (contracts.parseTextDiagnostic(line)) |diagnostic| {
            // Stderr is explicitly a compatibility fallback, not a trusted
            // artifact. Drop unsafe paths rather than reflecting them or
            // turning an otherwise useful command result into an API error.
            const source_path = copySourcePath(allocator, diagnostic.source_path) catch null;
            try appendProblem(allocator, config, mode, compiler_id, failure_class, problems, .{
                .severity = diagnostic.severity,
                .code = diagnostic.code,
                .message = diagnostic.message,
                .remediation = "",
                .source_path = source_path,
                .line = diagnostic.line,
                .column = diagnostic.column,
                .id = null,
                .origin = .stderr,
                .position_confidence = if (source_path != null and diagnostic.line != null and diagnostic.column != null) .best_effort else .none,
            });
            continue;
        } else |_| {}

        const unstructured = unstructuredStderr(line) orelse continue;
        try appendProblem(allocator, config, mode, compiler_id, failure_class, problems, .{
            .severity = unstructured.severity,
            .code = null,
            .message = unstructured.message,
            .remediation = "",
            .source_path = null,
            .line = null,
            .column = null,
            .id = null,
            .origin = .stderr,
            .position_confidence = .none,
        });
    }
}

fn appendProblem(
    allocator: std.mem.Allocator,
    config: Config,
    mode: Mode,
    compiler_id: []const u8,
    failure_class: FailureClass,
    problems: *std.ArrayList(Problem),
    input: struct {
        severity: contracts.Severity,
        code: ?[]const u8,
        message: []const u8,
        remediation: []const u8,
        source_path: ?[]const u8,
        line: ?u32,
        column: ?u32,
        id: ?[]const u8,
        origin: Origin,
        position_confidence: PositionConfidence,
    },
) !void {
    const code = if (input.code) |value| try cleanText(allocator, value, config.project_root, 128) else null;
    const message = try cleanText(allocator, input.message, config.project_root, 2048);
    const remediation = try cleanText(allocator, input.remediation, config.project_root, 2048);
    const id = if (input.id) |value| try cleanText(allocator, value, config.project_root, 512) else null;
    const packet = try diagnostic_packet.build(allocator, .{
        .compiler_id = compiler_id,
        .editor_id = config.editor_id,
        .command_mode = @tagName(mode),
        .failure_class = @tagName(failure_class),
        .severity = @tagName(input.severity),
        .code = code,
        .message = message,
        .remediation = remediation,
        .source_path = input.source_path,
        .line = input.line,
        .column = input.column,
        .origin = @tagName(input.origin),
        .position_confidence = @tagName(input.position_confidence),
        .private_project_root = config.project_root,
    });
    try problems.append(allocator, .{
        .severity = input.severity,
        .code = code,
        .message = message,
        .remediation = remediation,
        .source_path = input.source_path,
        .line = input.line,
        .column = input.column,
        .id = id,
        .origin = input.origin,
        .position_confidence = input.position_confidence,
        .packet = packet,
    });
}

fn appendProcessProblem(
    allocator: std.mem.Allocator,
    config: Config,
    mode: Mode,
    compiler_id: []const u8,
    failure_class: FailureClass,
    message: []const u8,
    problems: *std.ArrayList(Problem),
) !void {
    try appendProblem(allocator, config, mode, compiler_id, failure_class, problems, .{
        .severity = .@"error",
        .code = null,
        .message = message,
        .remediation = "Inspect the Boris host terminal and retry after correcting the reported failure.",
        .source_path = null,
        .line = null,
        .column = null,
        .id = null,
        .origin = .process,
        .position_confidence = .none,
    });
}

fn appendFindings(allocator: std.mem.Allocator, private_root: []const u8, document: *const contracts.Document, findings: *std.ArrayList(Finding)) !void {
    const views = contracts.extractFindings(allocator, document) catch return error.UnsupportedArtifact;
    defer allocator.free(views);
    for (views) |finding| try findings.append(allocator, .{
        .code = try cleanText(allocator, finding.code, private_root, 128),
        .endpoint_type = finding.endpoint_type,
        .value = try cleanText(allocator, finding.value, private_root, 512),
        .count = finding.count,
        .source_path = try copySourcePath(allocator, finding.source_path),
        .line = finding.line,
        .column = finding.column,
    });
}

fn appendImpact(allocator: std.mem.Allocator, private_root: []const u8, document: *const contracts.Document, impact: *std.ArrayList(ImpactEndpoint)) !void {
    const views = contracts.extractImpact(allocator, document) catch return error.UnsupportedArtifact;
    defer allocator.free(views);
    for (views) |endpoint| try impact.append(allocator, .{
        .endpoint_type = endpoint.endpoint_type,
        .value = try cleanText(allocator, endpoint.value, private_root, 512),
    });
}

/// Builds a validate-mode Result from an html-build-report document without
/// spawning the compiler. Used by the long-lived validation daemon (#652):
/// the report file is the single authority for diagnostics, and the cycle's
/// `ok` field maps to the same outcome convention as the one-shot path
/// (0 success, 1 content failure), so existing consumers keep working.
pub fn resultFromReport(
    allocator: std.mem.Allocator,
    config: Config,
    compiler_id: []const u8,
    bytes: []const u8,
) !Result {
    var document = contracts.readHtmlBuildReport(allocator, bytes) catch return error.UnsupportedArtifact;
    defer document.deinit();
    const ok = contracts.htmlReportOk(&document) catch return error.UnsupportedArtifact;
    const failure_class: FailureClass = if (ok) .success else .content;
    const exit_code: ?u8 = if (ok) 0 else 1;
    var problems: std.ArrayList(Problem) = .empty;
    try appendStructuredProblems(allocator, config, .validate, compiler_id, failure_class, &document, .build_report, &problems);
    if (failure_class != .success and problems.items.len == 0) {
        try appendProcessProblem(allocator, config, .validate, compiler_id, failure_class, fallbackFailureMessage(failure_class), &problems);
    }
    return .{
        .mode = .validate,
        .exit_code = exit_code,
        .failure_class = failure_class,
        .compiler_id = compiler_id,
        .report_version = try allocator.dupe(u8, document.version),
        .used_stderr_fallback = false,
        .problems = try problems.toOwnedSlice(allocator),
        .findings = try allocator.alloc(Finding, 0),
        .impact = try allocator.alloc(ImpactEndpoint, 0),
        .publication_plan = null,
        .recipe_scale_view = null,
    };
}

/// A Result for a command that never produced a compiler run: timeouts,
/// stream overruns, or — for the validation daemon — a daemon that died or
/// could not be started. `exit_code`, when known, preserves the compiler's
/// contracted exit-code convention (0 success, 1 content, 2 usage, 3 I/O).
pub fn processFailureResult(
    allocator: std.mem.Allocator,
    config: Config,
    mode: Mode,
    compiler_id: []const u8,
    class: FailureClass,
    exit_code: ?u8,
    message: []const u8,
) !Result {
    var problems: std.ArrayList(Problem) = .empty;
    try appendProcessProblem(allocator, config, mode, compiler_id, class, message, &problems);
    return .{
        .mode = mode,
        .exit_code = exit_code,
        .failure_class = class,
        .compiler_id = compiler_id,
        .report_version = null,
        .used_stderr_fallback = true,
        .problems = try problems.toOwnedSlice(allocator),
        .findings = try allocator.alloc(Finding, 0),
        .impact = try allocator.alloc(ImpactEndpoint, 0),
        .publication_plan = null,
        .recipe_scale_view = null,
    };
}

fn termExitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

fn classifyTerm(term: std.process.Child.Term) FailureClass {
    const code = termExitCode(term) orelse return .terminated;
    return switch (code) {
        0 => .success,
        1 => .content,
        2 => .usage,
        3 => .io,
        else => .terminated,
    };
}

fn structuredConfidence(source_path: ?[]const u8, code: []const u8, line: ?u32, column: ?u32) PositionConfidence {
    if (line == null or column == null or line.? == 0 or column.? == 0) return .none;
    if (source_path) |path| {
        if (std.mem.endsWith(u8, path, ".cook") and !std.mem.eql(u8, code, "ECOOKLANG")) return .best_effort;
    }
    return .exact;
}

const Unstructured = struct { severity: contracts.Severity, message: []const u8 };

fn unstructuredStderr(line: []const u8) ?Unstructured {
    inline for (.{
        .{ "error: ", contracts.Severity.@"error" },
        .{ "warning: ", contracts.Severity.warning },
        .{ "info: ", contracts.Severity.info },
    }) |prefix| {
        if (std.mem.startsWith(u8, line, prefix[0]) and line.len > prefix[0].len) {
            return .{ .severity = prefix[1], .message = line[prefix[0].len..] };
        }
    }
    return null;
}

fn copySourcePath(allocator: std.mem.Allocator, optional_path: ?[]const u8) !?[]const u8 {
    const path = optional_path orelse return null;
    try validateSourcePath(path);
    const owned: []const u8 = try allocator.dupe(u8, path);
    return owned;
}

fn validateSourcePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\\x00") != null) return error.UnsafeArtifact;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.UnsafeArtifact;
    }
}

fn parseRecipeScaleView(allocator: std.mem.Allocator, stdout: []const u8) !std.json.Value {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, stdout, .{}) catch return error.UnsupportedArtifact;
    if (value != .object) return error.UnsupportedArtifact;
    const format = value.object.get("format") orelse return error.UnsupportedArtifact;
    if (format != .string or !std.mem.eql(u8, format.string, "boris-recipe-scale")) return error.UnsupportedArtifact;
    return value;
}

fn validateRecipeScaleId(id: []const u8) !void {
    if (id.len == 0 or id.len > 4096 or id[0] == '-' or !std.unicode.utf8ValidateSlice(id) or std.mem.indexOfAny(u8, id, "\x00\r\n") != null) {
        return error.InvalidRecipeScaleId;
    }
}

fn validateRecipeScaleFactor(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0 or trimmed.len > 64 or trimmed[0] == '-' or !std.unicode.utf8ValidateSlice(trimmed) or std.mem.indexOfAny(u8, trimmed, "\x00\r\n") != null) {
        return error.InvalidRecipeScaleFactor;
    }
}

fn validateImpactId(id: []const u8) !void {
    if (id.len == 0 or id.len > 4096 or id[0] == '-' or !std.unicode.utf8ValidateSlice(id) or std.mem.indexOfAny(u8, id, "\x00\r\n") != null) {
        return error.InvalidImpactId;
    }
}

fn validateProfilePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 1024 or path[0] == '-' or !std.unicode.utf8ValidateSlice(path)) return error.InvalidProfilePath;
    try validateSourcePath(path);
}

fn cleanText(allocator: std.mem.Allocator, input: []const u8, private_root: []const u8, max_bytes: usize) ![]const u8 {
    const replaced = if (private_root.len > 0)
        try std.mem.replaceOwned(u8, allocator, input, private_root, "<project>")
    else
        try allocator.dupe(u8, input);
    defer allocator.free(replaced);
    const end = utf8BoundedEnd(replaced, max_bytes);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, end + 3);
    for (replaced[0..end]) |byte| try output.append(allocator, if (byte < 0x20 or byte == 0x7f) ' ' else byte);
    if (end < replaced.len) try output.appendSlice(allocator, "...");
    return output.toOwnedSlice(allocator);
}

fn utf8BoundedEnd(input: []const u8, max_bytes: usize) usize {
    if (input.len <= max_bytes) return input.len;
    var end = max_bytes;
    while (end > 0 and !std.unicode.utf8ValidateSlice(input[0..end])) : (end -= 1) {}
    return end;
}

fn fallbackFailureMessage(class: FailureClass) []const u8 {
    return switch (class) {
        .success => "Boris completed successfully.",
        .content => "Boris reported a content or graph failure without a parseable diagnostic.",
        .usage => "Boris reported a usage or configuration failure.",
        .io => "Boris reported an I/O or system failure.",
        .terminated => "Boris terminated without a contracted exit code.",
    };
}

test "report results map ok to the one-shot outcome convention" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const config: Config = .{
        .project_root = "/private/project",
        .boris_path = "boris",
        .editor_id = "boris-editor/test",
    };

    const ok_result = try resultFromReport(arena.allocator(), config, "boris/test",
        \\{"schemaVersion":"html-build-report-0.1.0","compilerId":"boris/test","ok":true,"contentRoot":"content","outDir":"dist","errorCount":0,"diagnostics":[]}
    );
    try std.testing.expectEqual(FailureClass.success, ok_result.failure_class);
    try std.testing.expectEqual(@as(?u8, 0), ok_result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), ok_result.problems.len);
    try std.testing.expect(!ok_result.used_stderr_fallback);
    try std.testing.expectEqualStrings("html-build-report-0.1.0", ok_result.report_version.?);

    const failed_result = try resultFromReport(arena.allocator(), config, "boris/test",
        \\{"schemaVersion":"html-build-report-0.1.0","compilerId":"boris/test","ok":false,"contentRoot":"content","outDir":"dist","errorCount":1,"diagnostics":[{"severity":"error","code":"EFRONTMATTER","message":"bad.md:2:1: unknown key","remediation":"remove the unknown key","sourcePath":"bad.md","line":2,"column":1,"id":null}]}
    );
    try std.testing.expectEqual(FailureClass.content, failed_result.failure_class);
    try std.testing.expectEqual(@as(?u8, 1), failed_result.exit_code);
    try std.testing.expectEqual(@as(usize, 1), failed_result.problems.len);
    try std.testing.expectEqualStrings("EFRONTMATTER", failed_result.problems[0].code.?);
    try std.testing.expectEqual(PositionConfidence.exact, failed_result.problems[0].position_confidence);
}

test "process failure results preserve the contracted exit code" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const config: Config = .{
        .project_root = "/private/project",
        .boris_path = "boris",
        .editor_id = "boris-editor/test",
    };
    const result = try processFailureResult(arena.allocator(), config, .validate, "boris/test", .io, 3, "daemon stopped");
    try std.testing.expectEqual(@as(?u8, 3), result.exit_code);
    try std.testing.expectEqual(FailureClass.io, result.failure_class);
    try std.testing.expect(result.used_stderr_fallback);
}

test "exit classes remain distinct" {
    try std.testing.expectEqual(FailureClass.success, classifyTerm(.{ .exited = 0 }));
    try std.testing.expectEqual(FailureClass.content, classifyTerm(.{ .exited = 1 }));
    try std.testing.expectEqual(FailureClass.usage, classifyTerm(.{ .exited = 2 }));
    try std.testing.expectEqual(FailureClass.io, classifyTerm(.{ .exited = 3 }));
    try std.testing.expectEqual(FailureClass.terminated, classifyTerm(.{ .exited = 9 }));
}

test "stderr fallback keeps structured locations best-effort and bare failures unstructured" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    const config: Config = .{
        .project_root = "/private/project",
        .boris_path = "boris",
        .editor_id = "boris-editor/test",
    };
    try appendStderrProblems(
        arena.allocator(),
        config,
        .validate,
        "boris/test",
        .content,
        "error: EFRONTMATTER: bad.md:2:1: unknown key\nerror: target 'default' failed to load layout: LayoutDuplicateMarker\nboris: load\n",
        &problems,
    );
    try std.testing.expectEqual(@as(usize, 2), problems.items.len);
    try std.testing.expectEqualStrings("EFRONTMATTER", problems.items[0].code.?);
    try std.testing.expectEqual(PositionConfidence.best_effort, problems.items[0].position_confidence);
    try std.testing.expect(problems.items[1].code == null);
    try std.testing.expectEqual(PositionConfidence.none, problems.items[1].position_confidence);
}

test "impact ids cannot become command options" {
    try validateImpactId("guides/getting-started");
    try std.testing.expectError(error.InvalidImpactId, validateImpactId("--help"));
    try std.testing.expectError(error.InvalidImpactId, validateImpactId("bad\nvalue"));
}

test "cooklang trees append the compiler selector; markdown trees do not" {
    const allocator = std.testing.allocator;
    const cook = try commandArgv(allocator, "boris", .{ .mode = .validate }, .cooklang);
    defer allocator.free(cook);
    try std.testing.expectEqualStrings("--cooklang", cook[cook.len - 1]);

    const md = try commandArgv(allocator, "boris", .{ .mode = .ir_build }, .markdown);
    defer allocator.free(md);
    try std.testing.expect(md.len >= 2);
    try std.testing.expect(!std.mem.eql(u8, md[md.len - 1], "--cooklang"));

    const html = try commandArgv(allocator, "boris", .{ .mode = .html_build }, .markdown);
    defer allocator.free(html);
    var saw_report = false;
    for (html) |arg| {
        if (std.mem.eql(u8, arg, "--report")) saw_report = true;
    }
    try std.testing.expect(saw_report);
}

test "recipe-scale argv is the fixed compiler command" {
    const allocator = std.testing.allocator;
    const argv = try commandArgv(allocator, "boris", .{
        .mode = .recipe_scale,
        .recipe_scale_id = "carbonara",
        .recipe_scale_factor = "2",
    }, .cooklang);
    defer allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 9), argv.len);
    try std.testing.expectEqualStrings("recipe-scale", argv[1]);
    try std.testing.expectEqualStrings("--input", argv[2]);
    try std.testing.expectEqualStrings("content", argv[3]);
    try std.testing.expectEqualStrings("--id", argv[4]);
    try std.testing.expectEqualStrings("carbonara", argv[5]);
    try std.testing.expectEqualStrings("--factor", argv[6]);
    try std.testing.expectEqualStrings("2", argv[7]);
    try std.testing.expectEqualStrings("--cooklang", argv[8]);

    try validateRecipeScaleId("carbonara");
    try validateRecipeScaleFactor("1 1/2");
    try std.testing.expectError(error.InvalidRecipeScaleId, validateRecipeScaleId("--help"));
    try std.testing.expectError(error.InvalidRecipeScaleFactor, validateRecipeScaleFactor("--factor"));
    try std.testing.expectError(error.InvalidRecipeScaleFactor, validateRecipeScaleFactor(""));
}

test "plan uses the selected profile and does not invent cooklang overrides" {
    const allocator = std.testing.allocator;
    const argv = try commandArgv(allocator, "boris", .{ .mode = .plan, .profile = "boris.json" }, .cooklang);
    defer allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("plan", argv[1]);
    try std.testing.expectEqualStrings("--profile", argv[2]);
    try std.testing.expectEqualStrings("boris.json", argv[3]);

    try validateProfilePath("standard-site.json");
    try std.testing.expectError(error.InvalidProfilePath, validateProfilePath("--help"));
    try std.testing.expectError(error.UnsafeArtifact, validateProfilePath("../secret.json"));
}
