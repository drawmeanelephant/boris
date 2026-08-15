//! Boris — product CLI entry (HTML default + IR + optional RAG).
//!
//! Typed flag parsing + exit-code model. Default mode builds an HTML site
//! under `dist/` (Oliver + Whiteboard + layout splice). IR mode (`--out` /
//! `--no-rag`) runs the content compiler pipeline (scan → parse → PageDb →
//! graph validate → deterministic JSON IR). RAG mode reuses `pipeline.compile`
//! + exports a deterministic corpus.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const diagnostic = @import("diagnostic.zig");
const diag = @import("diag.zig");
const html_report = @import("html_report.zig");
const pipeline = @import("pipeline.zig");
const rag = @import("rag.zig");
const context = @import("context.zig");
const llms = @import("llms.zig");
const rss = @import("rss.zig");
const compile = @import("compile.zig");
const target = @import("target.zig");
const theme_mod = @import("theme.zig");
const intelligence = @import("intelligence.zig");
const json_out = @import("json_out.zig");
const publication_profile = @import("publication_profile.zig");
const publication_plan = @import("publication_plan.zig");
const init_mod = @import("init.zig");
const timings = @import("timings.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const Options = cli.Options;
pub const Mode = cli.Mode;
pub const parseOptions = cli.parseOptions;

const default_out = ".boris";
const default_rag = "rag";
const default_html = "dist";
const default_layout = "themes/boris/layouts/main.html";

/// Production runner: help text + IR / RAG / HTML pipelines.
const ProdRunner = struct {
    gpa: std.mem.Allocator,
    io: Io,

    pub fn printHelp(_: *const @This()) void {
        cli.printUsage();
    }

    /// Print the compiler version to stdout. Errors are swallowed: the
    /// version is informational and must never change the exit code.
    pub fn printVersion(self: *const @This()) void {
        const bytes = pipeline.compiler_id ++ "\n";
        var stdout_buffer: [128]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
        stdout_writer.interface.writeAll(bytes) catch return;
        stdout_writer.interface.flush() catch {};
    }

    pub fn reportUsage(_: *const @This(), err: cli.ParseError, bad_arg: ?[]const u8) void {
        cli.printParseError(err, bad_arg);
        cli.printUsage();
    }

    pub fn run(self: *const @This(), opts: Options) ExitCode {
        return runPipelineWithReport(self.io, self.gpa, opts);
    }
};

/// Map path validation errors (collisions, escapes, symlinks, empty dirs) to usage (exit code 2).
/// The diagnostic prints unconditionally: `--quiet` silences progress and
/// success output, never the reason for a nonzero exit.
fn mapPathError(err: anyerror) ?ExitCode {
    switch (err) {
        error.EmptyTargetDirectory,
        error.TargetOutputCollision,
        error.TargetOutputSymlink,
        error.WorkspaceEscape,
        => {
            std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
            return .usage;
        },
        else => return null,
    }
}

/// Map pipeline result to process exit code.
///
/// - validation / content errors → 1
/// - usage errors are handled before this (exit 2)
/// - I/O / system errors → 3
///
/// Runs without printing the `--timings` report: tests call this so the
/// machine-readable JSON never touches the process stdout (which is the test
/// runner's protocol channel under `zig build test`). The CLI entry point
/// uses `runPipelineWithReport` for the identical behavior plus the report.
pub fn runPipeline(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    return runPipelineTimed(io, gpa, opts, false).code;
}

/// CLI entry point: like `runPipeline`, but also emits the `--timings` JSON
/// report to stdout after the run finishes.
pub fn runPipelineWithReport(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    return runPipelineTimed(io, gpa, opts, true).code;
}

fn runPipelineTimed(io: Io, gpa: std.mem.Allocator, opts: Options, print_report: bool) struct { code: ExitCode } {
    var recorder: ?timings.Recorder = null;
    if (opts.timings) recorder = timings.Recorder.init(io);
    const recorder_ptr: ?*timings.Recorder = if (recorder) |*r| r else null;
    defer {
        if (recorder) |*r| {
            r.stopAll();
            if (print_report) {
                const label: []const u8 = switch (opts.command) {
                    .validate, .check, .impact, .plan => @tagName(opts.command),
                    else => @tagName(opts.mode),
                };
                printTimingsReport(io, gpa, r, label) catch {};
            }
        }
    }

    const code: ExitCode = if (opts.command == .plan)
        runPublicationPlan(io, gpa, opts, recorder_ptr)
    else if (opts.command == .init)
        runInit(io, gpa, opts)
    else if (opts.command == .validate)
        runValidate(io, gpa, opts, recorder_ptr)
    else if (opts.command == .check or opts.command == .impact)
        runIntelligence(io, gpa, opts, recorder_ptr)
    else switch (opts.mode) {
        .rag => runRag(io, gpa, opts, recorder_ptr),
        .context => runContext(io, gpa, opts, recorder_ptr),
        .llms => runLlms(io, gpa, opts, recorder_ptr),
        .rss => runRss(io, gpa, opts, recorder_ptr),
        .html => runHtml(io, gpa, opts, recorder_ptr),
        .ir => s: {
            break :s runPipelineIr(io, gpa, opts, recorder_ptr);
        },
    };

    return .{ .code = code };
}

fn runPipelineIr(io: Io, gpa: std.mem.Allocator, opts: Options, recorder_ptr: ?*timings.Recorder) ExitCode {
    const out_dir = opts.out_dir orelse default_out;

    var result = pipeline.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = out_dir,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .timings = recorder_ptr,
    }) catch |err| {
        if (mapPathError(err)) |code| return code;
        std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (result.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items, opts.quiet) catch {
            return .io_error;
        };
    }

    if (result.ok) {
        if (!opts.quiet) {
            std.debug.print("ok: wrote IR under {s} ({d} page(s))\n", .{ out_dir, result.pages.items.len });
        }
        return .success;
    }

    return switch (result.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Write the `--timings` JSON report to stdout. Errors are swallowed: the
/// report is observational and must never change the exit code or artifacts.
fn printTimingsReport(io: Io, gpa: std.mem.Allocator, recorder: *const timings.Recorder, label: []const u8) !void {
    const bytes = try recorder.renderJson(gpa, label);
    defer gpa.free(bytes);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(bytes);
    try stdout_writer.interface.flush();
}

/// Read, normalize, validate, and declare one explicitly selected profile.
/// This path intentionally stops before content discovery or any publisher.
/// Materialize a deterministic starter site into `opts.init_dir` (default ".").
pub fn runInit(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const target_dir = opts.init_dir orelse ".";
    return @enumFromInt(init_mod.run(io, gpa, target_dir, opts.quiet));
}

pub fn runPublicationPlan(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    _ = recorder;
    const profile_path = opts.profile_path orelse return .usage;
    const profile_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        profile_path,
        gpa,
        .limited(publication_profile.max_profile_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return reportPublicationPlanConfigError(error.ProfileTooLarge),
        else => {
            std.debug.print("error: unable to read publication profile: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(profile_bytes);

    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| {
        std.debug.print("error: unable to resolve publication profile workspace: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(cwd_path);

    const workspace = publication_profile.profileWorkspace(gpa, cwd_path, profile_path) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    const profile_input_format: ?publication_profile.InputFormat = if (opts.profile_input_format_override) |format| switch (format) {
        .markdown => .markdown,
        .textile => .textile,
        .cook => .cook,
    } else null;

    var request = publication_profile.parseBytes(gpa, workspace, profile_bytes, .{
        .input = opts.profile_input_override,
        .input_format = profile_input_format,
        .html_output = opts.profile_html_output_override,
        .jobs = opts.jobs,
        .incremental = opts.incremental,
        .quiet = opts.quiet,
    }) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    defer request.deinit(gpa);

    const bytes = publication_plan.render(gpa, &request.plan) catch |err| {
        std.debug.print("error: unable to render publication plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(bytes);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout_writer.interface.writeAll(bytes) catch |err| {
        std.debug.print("error: unable to write publication plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    stdout_writer.interface.flush() catch |err| {
        std.debug.print("error: unable to flush publication plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    return .success;
}

fn reportPublicationPlanConfigError(err: anyerror) ExitCode {
    std.debug.print("error: invalid publication profile: {s}\n", .{@errorName(err)});
    return switch (err) {
        error.OutOfMemory => .io_error,
        else => .usage,
    };
}

/// Deterministic provenance-rich AI context export (same compile + graph validation as IR/RAG).
pub fn runContext(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const context_dir = opts.context_dir orelse "context";

    var result = context.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = context_dir,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .scope = opts.scope,
        .split_size = opts.split_size,
        .timings = recorder,
    }) catch |err| switch (err) {
        error.EmptyTargetDirectory,
        error.TargetOutputCollision,
        error.TargetOutputSymlink,
        error.WorkspaceEscape,
        => {
            std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
            return .usage;
        },
        error.InvalidScope, error.OversizedBlock => {
            std.debug.print("error: export projection failed: {s}\n", .{@errorName(err)});
            return .content_error;
        },
        else => {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer result.deinit();

    if (result.compile.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.compile.diagnostics.items, opts.quiet) catch {
            return .io_error;
        };
    }

    if (result.ok()) {
        if (!opts.quiet) {
            // The full validated graph count (may exceed the selected page
            // set under `--scope`); the bundle log labels the selected count
            // (#406).
            std.debug.print("ok: wrote context bundle under {s} ({d} graph page(s))\n", .{ context_dir, result.compile.pages.items.len });
        }
        return .success;
    }

    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Deterministic community `llms.txt` export using the shared validated graph.
pub fn runLlms(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const out_path = opts.llms_path orelse "llms.txt";
    var result = llms.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_path = out_path,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .publication_location = if (opts.publication_location) |*location| location else null,
        .timings = recorder,
    }) catch |err| {
        if (mapPathError(err)) |code| return code;
        std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();
    if (result.compile.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.compile.diagnostics.items, opts.quiet) catch return .io_error;
    }
    if (result.ok()) {
        if (!opts.quiet) std.debug.print("ok: wrote llms.txt under {s} ({d} page(s))\n", .{ out_path, result.compile.pages.items.len });
        return .success;
    }
    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Deterministic RSS 2.0 export using the shared validated graph.
pub fn runRss(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const out_path = opts.rss_path orelse "rss.xml";
    var result = rss.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_path = out_path,
        .site_url = opts.site_url orelse return .usage,
        .title = opts.rss_title orelse return .usage,
        .description = opts.rss_description orelse return .usage,
        .limit = opts.rss_limit,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .publication_location = if (opts.publication_location) |*location| location else null,
        .timings = recorder,
    }) catch |err| {
        if (mapPathError(err)) |code| return code;
        switch (err) {
            error.InvalidSiteUrl, error.InvalidLimit, error.AbsolutePath => {
                std.debug.print("error: invalid RSS configuration: {s}\n", .{@errorName(err)});
                return .usage;
            },
            error.PublicationLocationMismatch => {
                std.debug.print("error: RSS publication URL does not match the declared Pages location\n", .{});
                return .content_error;
            },
            error.InvalidXml => {
                std.debug.print("error: RSS projection validation failed: {s}\n", .{@errorName(err)});
                return .content_error;
            },
            else => {
                std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
                return .io_error;
            },
        }
    };
    defer result.deinit();
    if (result.compile.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.compile.diagnostics.items, opts.quiet) catch return .io_error;
    }
    if (result.ok()) {
        if (!opts.quiet) std.debug.print("ok: wrote RSS 2.0 feed to {s} ({d} page(s))\n", .{ out_path, result.compile.pages.items.len });
        return .success;
    }
    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Read-only graph analysis. This intentionally calls pipeline.compile rather
/// than pipeline.run, so no IR/RAG/HTML artifacts or cache manifests publish.
pub fn runIntelligence(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    var result = pipeline.compile(io, gpa, .{
        .content_root = opts.input_dir,
        .quiet = true,
        .input_format = opts.input_format,
        .timings = recorder,
    }) catch |err| {
        std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (!result.ok) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items, opts.quiet) catch return .io_error;
        return switch (result.failure) {
            .io => .io_error,
            .content, .none => .content_error,
        };
    }

    var pages: std.ArrayListUnmanaged(intelligence.Page) = .empty;
    defer pages.deinit(gpa);
    pages.ensureTotalCapacity(gpa, result.pages.items.len) catch return .io_error;
    for (result.pages.items) |page| {
        pages.appendAssumeCapacity(.{ .id = page.id, .parent = page.parent });
    }

    var edges: std.ArrayListUnmanaged(intelligence.Edge) = .empty;
    defer edges.deinit(gpa);
    edges.ensureTotalCapacity(gpa, result.edges.items.len) catch return .io_error;
    for (result.edges.items) |edge| {
        edges.appendAssumeCapacity(.{
            .from = .{ .type = @enumFromInt(@intFromEnum(edge.from.type)), .value = edge.from.value },
            .to = .{ .type = @enumFromInt(@intFromEnum(edge.to.type)), .value = edge.to.value },
            .kind = edge.kind,
        });
    }

    var requested: ?intelligence.Endpoint = null;
    if (opts.command == .impact) {
        const id = opts.impact_id orelse return .usage;
        var found = false;
        for (pages.items) |page| {
            if (std.mem.eql(u8, page.id, id)) {
                found = true;
                break;
            }
        }
        if (found) {
            requested = .{ .type = .page, .value = id };
        } else {
            // Source endpoints are not page records, but they are part of
            // the frozen dependency graph and are valid impact roots.
            for (result.edges.items) |edge| {
                const matches_source =
                    (edge.from.type == .source and std.mem.eql(u8, edge.from.value, id)) or
                    (edge.to.type == .source and std.mem.eql(u8, edge.to.value, id));
                if (matches_source) {
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            std.debug.print("error: impact target not found: {s}\n", .{id});
            return .usage;
        }
        if (requested == null) requested = .{ .type = .source, .value = id };
    }

    var report = intelligence.analyze(gpa, pages.items, edges.items, .{ .impact = requested }) catch |err| {
        std.debug.print("error: analysis failed: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer report.deinit();

    const rendered = if (opts.analysis_format == .json)
        renderAnalysisJson(gpa, opts, result.pages.items, result.edges.items, &report) catch return .io_error
    else
        renderAnalysisHuman(gpa, opts, result.pages.items, &report) catch return .io_error;
    defer gpa.free(rendered);

    if (opts.analysis_report) |path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rendered }) catch |err| {
            std.debug.print("error: failed to write report {s}: {s}\n", .{ path, @errorName(err) });
            return .io_error;
        };
    } else {
        std.debug.print("{s}", .{rendered});
    }

    // `check` is CI-useful by default: unreferenced pages are findings.
    // Unreferenced pages are ordinary findings by default; the check-only flag
    // opts into treating them as a content failure.
    if (opts.command == .check and opts.fail_on_unreferenced and report.summary.unreferenced_pages > 0) {
        return .content_error;
    }
    return .success;
}

/// Authoritative no-publication HTML source/target validation.
///
/// This enters the same in-process compiler coordinator as a normal HTML build
/// and returns at its explicit prepublication boundary. It never invokes a
/// build in a temporary directory and never emits an authority/report file.
pub fn runValidate(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const layout_path = opts.html_layout;
    const out_dir = opts.html_dir orelse default_html;

    var report_collector: ?diag.Collector = null;
    if (opts.report_path != null) report_collector = diag.Collector.init(gpa, io);
    defer if (report_collector) |*c| c.deinit();
    const collector_ptr: ?*diag.Collector = if (report_collector) |*c| c else null;

    compile.validateHtmlSiteMulti(io, gpa, opts.targets.items, .{
        .content_root = opts.input_dir,
        .layout_path = layout_path,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .sitemap_path = opts.sitemap_path,
        .site_url = opts.site_url,
        .publication_location = if (opts.publication_location) |*location| location else null,
        .allow_markdown_literals = opts.allow_markdown_links,
        .timings = recorder,
        .diagnostics = collector_ptr,
    }) catch |err| {
        const code = mapHtmlError(err, opts.targets.items, layout_path);
        appendEscapedDiagnostic(collector_ptr, err, code);
        writeHtmlReport(io, gpa, opts, collector_ptr, false, out_dir);
        return code;
    };

    if (!opts.quiet) {
        std.debug.print("ok: validation passed for {d} target(s)\n", .{opts.targets.items.len});
    }
    writeHtmlReport(io, gpa, opts, collector_ptr, true, out_dir);
    return .success;
}

/// Append one diagnostic for a compile error that escaped as a bare exit-code
/// mapping (usage / I/O classes), so the machine-readable report still
/// explains the nonzero exit even when the failing phase had no structured
/// diagnostic of its own.
fn appendEscapedDiagnostic(collector: ?*diag.Collector, err: anyerror, code: ExitCode) void {
    if (collector) |c| c.append(.{
        .severity = .error_,
        .code = if (code == .usage) .EUSAGE else .EIO,
        .message = @errorName(err),
        .remediation = "See the stderr diagnostic for the full explanation",
    });
}

/// Write the HTML-path diagnostics report (`--report PATH`) deterministically
/// on success and failure. Never changes the exit code or stderr text.
fn writeHtmlReport(
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    collector: ?*diag.Collector,
    ok: bool,
    out_dir: []const u8,
) void {
    const path = opts.report_path orelse return;
    const c = collector orelse return;
    diag.sortDiagnostics(c.list.items);
    const rendered = html_report.renderHtmlReport(gpa, pipeline.compiler_id, .{
        .ok = ok,
        .content_root = opts.input_dir,
        .out_dir = out_dir,
        .diagnostics = c.list.items,
    }) catch return;
    defer gpa.free(rendered);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rendered }) catch |err| {
        std.debug.print("error: failed to write report {s}: {s}\n", .{ path, @errorName(err) });
    };
}

fn renderAnalysisHuman(
    gpa: std.mem.Allocator,
    opts: Options,
    pages: []const pipeline.PageEntry,
    report: *const intelligence.Report,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendFmt(&out, gpa, "Documentation Intelligence ({s})\n", .{@tagName(opts.command)});
    try appendFmt(&out, gpa, "pages: {d} (roots {d}, satellites {d})\n", .{ report.summary.pages, report.summary.roots, report.summary.satellites });
    try appendFmt(&out, gpa, "source endpoints: {d}\nunreferenced pages: {d}\nhotspots: {d}\n", .{ report.summary.source_endpoints, report.summary.unreferenced_pages, report.summary.hotspots });
    if (opts.command == .impact) {
        try appendFmt(&out, gpa, "impact ({s}):\n", .{opts.impact_id.?});
        for (report.impact.items) |endpoint| try appendFmt(&out, gpa, "  {s}: {s}\n", .{ @tagName(endpoint.type), endpoint.value });
    }
    if (report.findings.items.len > 0) {
        try out.appendSlice(gpa, "findings:\n");
        for (report.findings.items) |finding| {
            try appendFmt(&out, gpa, "  {s}: {s}", .{ @tagName(finding.code), finding.endpoint.value });
            if (finding.count > 0) try appendFmt(&out, gpa, " ({d})", .{finding.count});
            try out.append(gpa, '\n');
        }
    }
    _ = pages;
    return out.toOwnedSlice(gpa);
}

fn appendFmt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const rendered = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(rendered);
    try buf.appendSlice(gpa, rendered);
}

const BufferWriter = struct {
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    pub fn writeAll(self: *@This(), bytes: []const u8) !void {
        try self.buf.appendSlice(self.gpa, bytes);
    }
};

fn renderAnalysisJson(
    gpa: std.mem.Allocator,
    opts: Options,
    pages: []const pipeline.PageEntry,
    edges: []const pipeline.DependencyEdge,
    report: *const intelligence.Report,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var w = BufferWriter{ .buf = &out, .gpa = gpa };
    try w.writeAll("{\n  \"format\": \"boris-documentation-intelligence\",\n  \"schemaVersion\": \"0.2.0\",\n  \"compiler\": ");
    try json_out.writeString(&out, gpa, pipeline.compiler_id);
    try w.writeAll(",\n  \"input\": ");
    try json_out.writeString(&out, gpa, opts.input_dir);
    try w.writeAll(",\n  \"summary\": {\n    \"pages\": ");
    try json_out.writeUsize(&out, gpa, report.summary.pages);
    try w.writeAll(",\n    \"roots\": ");
    try json_out.writeUsize(&out, gpa, report.summary.roots);
    try w.writeAll(",\n    \"satellites\": ");
    try json_out.writeUsize(&out, gpa, report.summary.satellites);
    try w.writeAll(",\n    \"sourceEndpoints\": ");
    try json_out.writeUsize(&out, gpa, report.summary.source_endpoints);
    try w.writeAll(",\n    \"unreferencedPages\": ");
    try json_out.writeUsize(&out, gpa, report.summary.unreferenced_pages);
    try w.writeAll(",\n    \"hotspots\": ");
    try json_out.writeUsize(&out, gpa, report.summary.hotspots);
    try w.writeAll("\n  },\n  \"nodes\": [");
    for (pages, 0..) |page, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"page\",\"id\":");
        try json_out.writeString(&out, gpa, page.id);
        try w.writeAll(",\"sourcePath\":");
        try json_out.writeString(&out, gpa, page.source_path);
        try w.writeAll(",\"parent\":");
        if (page.parent) |parent| try json_out.writeString(&out, gpa, parent) else try json_out.writeNull(&out, gpa);
        try w.writeAll("}");
    }
    try w.writeAll("],\n  \"edges\": [");
    for (edges, 0..) |edge, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"from\":{\"type\":");
        try json_out.writeString(&out, gpa, @tagName(edge.from.type));
        try w.writeAll(",\"value\":");
        try json_out.writeString(&out, gpa, edge.from.value);
        try w.writeAll("},\"to\":{\"type\":");
        try json_out.writeString(&out, gpa, @tagName(edge.to.type));
        try w.writeAll(",\"value\":");
        try json_out.writeString(&out, gpa, edge.to.value);
        try w.writeAll("},\"kind\":");
        try json_out.writeString(&out, gpa, edge.kind);
        try w.writeAll("}");
    }
    try w.writeAll("],\n  \"sourceLocations\": [");
    for (pages, 0..) |page, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"page\",\"value\":");
        try json_out.writeString(&out, gpa, page.id);
        try w.writeAll(",\"sourcePath\":");
        try json_out.writeString(&out, gpa, page.source_path);
        try w.writeAll(",\"line\":1,\"column\":1}");
    }
    try w.writeAll("],\n  \"pages\": [");
    for (pages, 0..) |page, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try json_out.writeString(&out, gpa, page.id);
        try w.writeAll(",\"parent\":");
        if (page.parent) |parent| try json_out.writeString(&out, gpa, parent) else try json_out.writeNull(&out, gpa);
        try w.writeAll("}");
    }
    try w.writeAll("],\n  \"sources\": [");
    var source_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer source_names.deinit(gpa);
    for (edges) |edge| {
        if (edge.to.type != .source) continue;
        var exists = false;
        for (source_names.items) |name| {
            if (std.mem.eql(u8, name, edge.to.value)) {
                exists = true;
                break;
            }
        }
        if (!exists) try source_names.append(gpa, edge.to.value);
    }
    std.mem.sort([]const u8, source_names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    for (source_names.items, 0..) |source, i| {
        if (i > 0) try w.writeAll(",");
        try json_out.writeString(&out, gpa, source);
    }
    try w.writeAll("],\n  \"findings\": [");
    for (report.findings.items, 0..) |finding, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"code\":");
        try json_out.writeString(&out, gpa, @tagName(finding.code));
        try w.writeAll(",\"type\":");
        try json_out.writeString(&out, gpa, @tagName(finding.endpoint.type));
        try w.writeAll(",\"value\":");
        try json_out.writeString(&out, gpa, finding.endpoint.value);
        try w.writeAll(",\"count\":");
        try json_out.writeUsize(&out, gpa, finding.count);
        try w.writeAll(",\"sourcePath\":");
        var finding_source: ?[]const u8 = null;
        if (finding.endpoint.type == .page) {
            for (pages) |page| {
                if (std.mem.eql(u8, page.id, finding.endpoint.value)) {
                    finding_source = page.source_path;
                    break;
                }
            }
        }
        if (finding_source) |source| try json_out.writeString(&out, gpa, source) else try json_out.writeNull(&out, gpa);
        try w.writeAll(",\"line\":");
        if (finding_source != null) try json_out.writeUsize(&out, gpa, 1) else try json_out.writeNull(&out, gpa);
        try w.writeAll(",\"column\":");
        if (finding_source != null) try json_out.writeUsize(&out, gpa, 1) else try json_out.writeNull(&out, gpa);
        try w.writeAll("}");
    }
    try w.writeAll("],\n  \"impact\": ");
    if (opts.command == .impact) {
        try w.writeAll("[");
        for (report.impact.items, 0..) |endpoint, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"type\":");
            try json_out.writeString(&out, gpa, @tagName(endpoint.type));
            try w.writeAll(",\"value\":");
            try json_out.writeString(&out, gpa, endpoint.value);
            try w.writeAll("}");
        }
        try w.writeAll("]");
    } else try json_out.writeNull(&out, gpa);
    try w.writeAll(",\n  \"diagnostics\": []\n}\n");
    return out.toOwnedSlice(gpa);
}

/// Optional deterministic RAG export (same compile + graph.validate as IR).
pub fn runRag(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const rag_dir = opts.rag_dir orelse default_rag;

    var result = rag.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = rag_dir,
        .system_docs_dir = "docs/rag/system",
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .scope = opts.scope,
        .split_size = opts.split_size,
        .bundles_only = opts.bundles_only,
        .complete = opts.complete,
        .timings = recorder,
    }) catch |err| switch (err) {
        error.EmptyTargetDirectory,
        error.TargetOutputCollision,
        error.TargetOutputSymlink,
        error.WorkspaceEscape,
        => {
            std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
            return .usage;
        },
        error.InvalidScope, error.OversizedBlock, error.SeparatorCollision => {
            std.debug.print("error: export projection failed: {s}\n", .{@errorName(err)});
            return .content_error;
        },
        else => {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer result.deinit();

    if (result.diagnostics().len > 0) {
        pipeline.printDiagnostics(gpa, result.diagnostics(), opts.quiet) catch {
            return .io_error;
        };
    }

    if (result.ok()) {
        if (!opts.quiet) {
            if (result.stats.complete) {
                std.debug.print("ok: wrote complete RAG corpus under {s} ({d} page(s), {d} catalog entries)\n", .{ rag_dir, result.stats.content_pages, result.stats.catalog_entries });
            } else {
                std.debug.print(
                    \\ok: wrote RAG working context under {s}
                    \\  Selected pages: {d} / {d}
                    \\  Structural context: {d} parent page(s), {d} semantic neighbor(s)
                    \\  System context: {d} seed(s)
                    \\  Upload files ({d}):
                    \\
                , .{
                    rag_dir,
                    result.stats.selected_pages,
                    result.stats.graph_pages,
                    result.stats.structural_parent_count,
                    result.stats.semantic_neighbor_count,
                    result.stats.system_docs,
                    result.stats.pack_count,
                });
                for (result.stats.pack_paths) |pack_path| {
                    std.debug.print("    {s}\n", .{pack_path});
                }
                std.debug.print(
                    \\  Approximate upload bytes: {d}
                    \\  Approximate tokens: {d}
                    \\  Non-upload sidecar: manifest.json ({d} file)
                    \\
                    \\
                , .{
                    result.stats.approximate_bytes,
                    result.stats.approximate_tokens,
                    result.stats.sidecar_count,
                });
            }
        }
        return .success;
    }

    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// HTML site render via the Oliver-backed seam + whiteboard arena (default CLI path).
pub fn runHtml(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const html_dir = opts.html_dir orelse default_html;

    const layout_path = opts.html_layout;

    if (opts.watch) {
        const watch = @import("watch.zig");
        var watcher = watch.PollingWatcher.init(gpa, io);
        defer watcher.deinit();

        watcher.addRoot(opts.input_dir) catch |err| {
            return mapHtmlError(err, opts.targets.items, layout_path);
        };

        // Watch unique layout parent directories (global + per-target overrides).
        var layout_roots: std.StringHashMapUnmanaged(void) = .{};
        defer layout_roots.deinit(gpa);
        const add_layout_root = struct {
            fn go(w: *watch.PollingWatcher, map: *std.StringHashMapUnmanaged(void), gpa_: std.mem.Allocator, lp: []const u8, input_dir: []const u8) !void {
                // A managed theme root owns `layouts/`, optional `footer.html` and
                // `assets/`. Watch the whole root, not just the layout's parent:
                // footer and referenced asset bytes are page-fingerprint inputs
                // (F9.1), so edits under `<theme>/assets/` must produce events or
                // `--watch` serves stale output (#59). scanFiles is recursive, so
                // this also covers `layouts/`; a missing dir scans to nothing.
                if (theme_mod.themeRootFromLayoutPath(lp)) |theme_root| {
                    if (std.mem.eql(u8, theme_root, input_dir)) return; // content root covers it
                    const t_gop = try map.getOrPut(gpa_, theme_root);
                    if (!t_gop.found_existing) {
                        try w.addRoot(theme_root);
                    }
                    return;
                }
                // Bare filename (no dirname) — watch the file via its parent only when
                // that parent is not the whole cwd (which would scan .git/dist every poll).
                // Prefer not adding "." when content is already watched under input_dir.
                const dir = std.fs.path.dirname(lp) orelse {
                    // Layout sits at repo root as a bare name: do not addRoot(".") —
                    // the layout file is still picked up if it lives under a watched root;
                    // otherwise watch only that single path's parent when it equals input_dir.
                    if (std.mem.eql(u8, input_dir, ".") or std.mem.eql(u8, input_dir, "./")) {
                        return; // content root already covers cwd
                    }
                    return; // skip cwd-wide layout root (issue #18)
                };
                // Skip layout parent if it is already covered by content root.
                if (std.mem.eql(u8, dir, input_dir)) return;
                const gop = try map.getOrPut(gpa_, dir);
                if (!gop.found_existing) {
                    try w.addRoot(dir);
                }
            }
        }.go;
        add_layout_root(&watcher, &layout_roots, gpa, layout_path, opts.input_dir) catch |err| {
            return mapHtmlError(err, opts.targets.items, layout_path);
        };
        for (opts.targets.items) |t| {
            if (t.layout_path) |lp| {
                add_layout_root(&watcher, &layout_roots, gpa, lp, opts.input_dir) catch |err| {
                    return mapHtmlError(err, opts.targets.items, layout_path);
                };
            }
            for (t.layout_rules) |rule| {
                add_layout_root(&watcher, &layout_roots, gpa, rule.layout_path, opts.input_dir) catch |err| {
                    return mapHtmlError(err, opts.targets.items, layout_path);
                };
            }
        }

        var coord = watch.WatchCoordinator.init(gpa, io, opts, watcher.watcher()) catch |err| {
            return mapHtmlError(err, opts.targets.items, layout_path);
        };
        defer coord.deinit();

        coord.run() catch |err| {
            return mapHtmlError(err, opts.targets.items, layout_path);
        };

        return .success;
    }

    var report_collector: ?diag.Collector = null;
    if (opts.report_path != null) report_collector = diag.Collector.init(gpa, io);
    defer if (report_collector) |*c| c.deinit();
    const collector_ptr: ?*diag.Collector = if (report_collector) |*c| c else null;

    if (opts.targets.items.len > 0) {
        compile.compileHtmlSiteMulti(io, gpa, opts.targets.items, .{
            .content_root = opts.input_dir,
            .layout_path = layout_path,
            .incremental = opts.incremental,
            .quiet = opts.quiet,
            .jobs = opts.jobs,
            .input_format = opts.input_format,
            .sitemap_path = opts.sitemap_path,
            .site_url = opts.site_url,
            .publication_location = if (opts.publication_location) |*location| location else null,
            .allow_markdown_literals = opts.allow_markdown_links,
            .timings = recorder,
            .diagnostics = collector_ptr,
        }) catch |err| {
            const code = mapHtmlError(err, opts.targets.items, layout_path);
            appendEscapedDiagnostic(collector_ptr, err, code);
            writeHtmlReport(io, gpa, opts, collector_ptr, false, html_dir);
            return code;
        };

        if (!opts.quiet) {
            // Canonical order + effective paths (parse already sorts by name).
            std.debug.print("ok: wrote HTML for {d} target(s):\n", .{opts.targets.items.len});
            target.printTargetConfigLines(opts.targets.items, layout_path);
        }
    } else {
        const stats = compile.compileHtmlSite(io, gpa, .{
            .content_root = opts.input_dir,
            .dist_dir = html_dir,
            .layout_path = layout_path,
            .incremental = opts.incremental,
            .quiet = opts.quiet,
            .jobs = opts.jobs,
            .input_format = opts.input_format,
            .sitemap_path = opts.sitemap_path,
            .site_url = opts.site_url,
            .publication_location = if (opts.publication_location) |*location| location else null,
            .allow_markdown_literals = opts.allow_markdown_links,
            .timings = recorder,
            .diagnostics = collector_ptr,
        }) catch |err| {
            const code = mapHtmlError(err, &.{}, layout_path);
            appendEscapedDiagnostic(collector_ptr, err, code);
            writeHtmlReport(io, gpa, opts, collector_ptr, false, html_dir);
            return code;
        };

        if (!opts.quiet) {
            std.debug.print("ok: wrote HTML under {s} ({d} page(s))\n", .{ html_dir, stats.pages_written });
        }
    }
    writeHtmlReport(io, gpa, opts, collector_ptr, true, html_dir);
    return .success;
}

/// Map HTML compile failures to process exit codes.
/// Target configuration / path isolation → 2; content/layout/component → 1;
/// missing content root and I/O → 3.
///
/// Every branch that explains a failure prints unconditionally. `--quiet`
/// suppresses progress and success output, never the reason for a nonzero
/// exit; branches that print nothing here do so because the compiler already
/// emitted a structured diagnostic, not because the caller asked for silence.
fn mapHtmlError(
    err: anyerror,
    targets: []const target.TargetSpec,
    global_layout: []const u8,
) ExitCode {
    switch (err) {
        // Target configuration / path isolation — usage (exit 2), not I/O.
        error.NoTargetsSpecified,
        error.InvalidTargetName,
        error.DuplicateTargetName,
        error.EmptyTargetDirectory,
        error.TargetOutputCollision,
        error.TargetOutputSymlink,
        error.WorkspaceEscape,
        error.MixedThemeRoots,
        error.AmbiguousGlob,
        error.DuplicateSelector,
        error.InvalidLayoutPath,
        error.LayoutSelectionFailed,
        error.InvalidSiteUrl,
        error.InvalidSitemapPath,
        error.SitemapOutputCollision,
        error.SitemapSiteUrlRequired,
        error.SitemapSiteUrlWithoutOutput,
        error.AmbiguousSitemapTargets,
        => {
            std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
            if (targets.len > 0) {
                std.debug.print("configured targets (canonical order):\n", .{});
                target.printTargetConfigLines(targets, global_layout);
            }
            return .usage;
        },
        // Graph/include/wiki/component failures (and multi-target wrap) already print
        // structured diagnostics on the HTML path; re-printing @errorName only doubles noise.
        error.GraphValidationFailed,
        error.IncludeFailed,
        error.ReferenceFailed,
        error.ComponentFailed,
        error.SitemapDuplicateUrl,
        error.SitemapUrlLimitExceeded,
        error.SitemapSizeLimitExceeded,
        error.PublicationLocationMismatch,
        // The content-asset path already emitted the structured EASSET diagnostic
        // for rejected active SVGs; re-printing only doubles noise.
        error.AssetUnsafeSvg,
        // The output link audit already emitted structured route diagnostics;
        // classify the invalid publication as a content failure.
        error.LinkAuditFailed,
        // Multi-target wrap can mix content and I/O; prefer content for graph/include
        // failures already printed, but treat pure layout load I/O as exit 3 via FileNotFound etc.
        error.MultiTargetCompilationFailed,
        => return .content_error,
        // The HTML loader already emitted the structured ETEXTILE diagnostic.
        error.TextileFailed,
        error.InputFormatMismatch,
        => return .content_error,
        error.MultiTargetIoFailed => {
            std.debug.print("error: one or more HTML targets failed due to I/O or a system error\n", .{});
            return .io_error;
        },
        // The target commit is already visible when publication checks fail;
        // compile.zig emits the explicit "publication committed" diagnostic.
        error.PublicationChecksFailed => return .io_error,
        // The target, inventory, and checks report are already committed when
        // claims derivation fails; compile.zig emits the explicit "publication
        // committed" diagnostic for this evidence layer as well.
        error.PublicationClaimsFailed => return .io_error,
        error.PublicationTouchesFailed => return .io_error,
        // The target and all four evidence reports are already committed when
        // Proof Pack generation fails; compile.zig emits the explicit
        // "publication committed" diagnostic for this presentation layer.
        error.PublicationProofPackFailed => return .io_error,
        error.ParseFailed,
        error.LayoutMissingMarker,
        error.LayoutDuplicateMarker,
        error.LayoutUnknownMarker,
        error.LayoutTooManySegments,
        error.LayoutInvalidAssetUrl,
        error.LayoutTooManyAssetUrls,
        error.LayoutInvalidUtf8,
        error.AssetNotFound,
        error.AssetCollision,
        error.AssetSymlink,
        error.AssetPathEscape,
        error.AssetFailed,
        error.AssetPath,
        error.AssetMissing,
        error.AssetNotFile,
        error.ThemeRootMissing,
        error.InvalidThemePath,
        error.ThemeSymlink,
        error.FooterSymlink,
        error.FooterInvalidUtf8,
        => {
            std.debug.print("error: content or layout failure: {s}\n", .{@errorName(err)});
            return .content_error;
        },
        else => {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    }
}

/// Pure dispatch used by tests (injectable runner; no process.Init required).
pub fn runArgs(args: []const []const u8) u8 {
    var runner: SilentRunner = .{};
    return cli.runArgs(args, &runner);
}

/// Zig 0.16 entry: main receives `std.process.Init` (gpa, arena, io, …).
pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();

    const args_z = init.minimal.args.toSlice(cold) catch {
        std.debug.print("error: failed to read process arguments\n", .{});
        return ExitCode.io_error.int();
    };

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(cold);
    args_list.ensureTotalCapacity(cold, args_z.len) catch {
        std.debug.print("error: out of memory parsing arguments\n", .{});
        return ExitCode.io_error.int();
    };
    for (args_z) |a| {
        args_list.appendAssumeCapacity(a);
    }

    const runner: ProdRunner = .{
        .gpa = init.gpa,
        .io = init.io,
    };
    return cli.runArgs(args_list.items, &runner);
}

// --- main-level exit-code mapping tests ------------------------------------

/// Silent runner for CLI-only tests: no help/version/usage/pipeline I/O.
const SilentRunner = struct {
    pipeline_calls: usize = 0,

    pub fn printVersion(self: *@This()) void {
        _ = self;
    }

    pub fn printHelp(self: *@This()) void {
        _ = self;
    }

    pub fn reportUsage(self: *@This(), err: cli.ParseError, bad_arg: ?[]const u8) void {
        _ = self;
        _ = @errorName(err);
        _ = bad_arg;
    }

    pub fn run(self: *@This(), opts: Options) ExitCode {
        _ = opts;
        self.pipeline_calls += 1;
        return .success;
    }
};

test "runArgs: documented exit code mapping" {
    var runner: SilentRunner = .{};

    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--help" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "-h" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--version" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "-V" }, &runner));
    try std.testing.expectEqual(@as(usize, 0), runner.pipeline_calls);

    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{"boris"}, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--quiet" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--no-rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--rag-dir", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--html" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--html-dir", "x" }, &runner));
    try std.testing.expect(runner.pipeline_calls >= 7);

    const before = runner.pipeline_calls;
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--rag", "--no-rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--rag", "--out", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--no-rag", "--rag-dir", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--html", "--rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--html", "--out", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--html-dir", "d", "--rag-dir", "r" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--unknown" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--input" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "positional" }, &runner));
    try std.testing.expectEqual(before, runner.pipeline_calls);
}

test "ExitCode contract surface" {
    try std.testing.expectEqual(@as(u8, 0), ExitCode.success.int());
    try std.testing.expectEqual(@as(u8, 1), ExitCode.content_error.int());
    try std.testing.expectEqual(@as(u8, 2), ExitCode.usage.int());
    try std.testing.expectEqual(@as(u8, 3), ExitCode.io_error.int());
}

test "mapHtmlError: multi-target I/O failure exits 3" {
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.MultiTargetIoFailed, &.{}, default_layout));
}

test "mapHtmlError: unsafe SVG content failure exits 1 without a generic wrapper" {
    // AssetUnsafeSvg already emitted the structured EASSET diagnostic from the
    // content-asset path; mapHtmlError must classify it as a content error
    // (exit 1) and must not print either generic wrapper line.
    try std.testing.expectEqual(ExitCode.content_error, mapHtmlError(error.AssetUnsafeSvg, &.{}, default_layout));
}

test "mapHtmlError: link-audit content failure exits 1" {
    try std.testing.expectEqual(ExitCode.content_error, mapHtmlError(error.LinkAuditFailed, &.{}, default_layout));
}

test "mapHtmlError: committed publication with stale checks evidence exits 3" {
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.PublicationChecksFailed, &.{}, default_layout));
}

test "mapHtmlError: committed publication with stale claims evidence exits 3" {
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.PublicationClaimsFailed, &.{}, default_layout));
}

test "mapHtmlError: committed publication with unrefreshed Touch Atlas exits 3" {
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.PublicationTouchesFailed, &.{}, default_layout));
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.PublicationProofPackFailed, &.{}, default_layout));
}

test "mapHtmlError: target configuration failures exit 2" {
    const specs = [_]target.TargetSpec{
        .{ .name = "prod", .output_dir = "dist/prod" },
    };
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.TargetOutputCollision, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.WorkspaceEscape, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.DuplicateTargetName, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.InvalidTargetName, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.TargetOutputSymlink, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.EmptyTargetDirectory, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.NoTargetsSpecified, &.{}, default_layout));
}

test "runPipeline: valid fixture exits 0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-valid", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .ir,
        .input_dir = "docs/contracts/fixtures/valid/content",
        .out_dir = out,
        .rag_dir = null,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.success, code);
}

test "runPipeline: unreferenced check findings are report-only unless opted in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const default_report = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/di-default.json", .{tmp.sub_path});
    defer gpa.free(default_report);
    const strict_report = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/di-strict.json", .{tmp.sub_path});
    defer gpa.free(strict_report);

    const base = Options{
        .command = .check,
        .input_dir = "docs/contracts/fixtures/documentation-intelligence/content",
        .analysis_format = .json,
        .analysis_report = default_report,
        .quiet = true,
    };
    try std.testing.expectEqual(ExitCode.success, runPipeline(io, gpa, base));

    var strict = base;
    strict.analysis_report = strict_report;
    strict.fail_on_unreferenced = true;
    try std.testing.expectEqual(ExitCode.content_error, runPipeline(io, gpa, strict));

    const cwd = Io.Dir.cwd();
    const default_bytes = try cwd.readFileAlloc(io, default_report, gpa, .unlimited);
    defer gpa.free(default_bytes);
    const strict_bytes = try cwd.readFileAlloc(io, strict_report, gpa, .unlimited);
    defer gpa.free(strict_bytes);
    try std.testing.expectEqualStrings(default_bytes, strict_bytes);
}

test "runPipeline: duplicate-id exits 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-dup", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .ir,
        .input_dir = "docs/contracts/fixtures/duplicate-ids/content",
        .out_dir = out,
        .rag_dir = null,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.content_error, code);
}

test "runPipeline: missing content root exits 3" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-noroot", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .ir,
        .input_dir = "docs/contracts/fixtures/__no_such_root__",
        .out_dir = out,
        .rag_dir = null,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.io_error, code);
}

test "runPipeline: valid RAG fixture exits 0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-rag", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .rag,
        .input_dir = "fixtures/content/valid",
        .out_dir = null,
        .rag_dir = out,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.success, code);
}

test "runPipeline: RAG invalid graph exits 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-rag-bad", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .rag,
        .input_dir = "docs/contracts/fixtures/duplicate-ids/content",
        .out_dir = null,
        .rag_dir = out,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.content_error, code);
}

test "runPipeline: HTML fixture exits 0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-html", .{tmp.sub_path});
    defer gpa.free(out);

    // Uses the repo's managed Boris theme (default_layout) + HTML content fixture.
    const code = runPipeline(io, gpa, .{
        .mode = .html,
        .input_dir = "test/fixtures/html/content",
        .out_dir = null,
        .rag_dir = null,
        .html_dir = out,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.success, code);

    // Smoke-check that a page landed under the HTML output root.
    const cwd = Io.Dir.cwd();
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out});
    defer gpa.free(index_path);
    var file = try cwd.openFile(io, index_path, .{});
    defer file.close(io);
}

test "runPipeline: --timings leaves exit codes and artifacts unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-timings", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .ir,
        .input_dir = "docs/contracts/fixtures/valid/content",
        .out_dir = out,
        .quiet = true,
        .timings = true,
    });
    // Same exit code as the non-timings run of the same fixture.
    try std.testing.expectEqual(ExitCode.success, code);

    // Published artifacts match the non-timings expectation.
    const cwd = Io.Dir.cwd();
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.json", .{out});
    defer gpa.free(manifest_path);
    const manifest_bytes = try cwd.readFileAlloc(io, manifest_path, gpa, .unlimited);
    defer gpa.free(manifest_bytes);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"pageCount\": 3") != null);
}

test "runPipeline: HTML missing content root exits 3" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-html-noroot", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .html,
        .input_dir = "docs/contracts/fixtures/__no_such_html_root__",
        .out_dir = null,
        .rag_dir = null,
        .html_dir = out,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.io_error, code);
}

test "runPipeline: multi-target HTML build success and validation exits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-multi-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-multi-b", .{tmp.sub_path});
    defer gpa.free(out_b);

    var opts = Options{
        .mode = .html,
        .input_dir = "test/fixtures/html/content",
        .quiet = true,
    };
    try opts.targets.append(gpa, .{ .name = "t_b", .output_dir = out_b });
    try opts.targets.append(gpa, .{ .name = "t_a", .output_dir = out_a });
    defer opts.targets.deinit(gpa);

    const code = runPipeline(io, gpa, opts);
    try std.testing.expectEqual(ExitCode.success, code);

    // Verify index.html in both
    const cwd = Io.Dir.cwd();
    const path_a = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out_a});
    defer gpa.free(path_a);
    const path_b = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out_b});
    defer gpa.free(path_b);

    var file_a = try cwd.openFile(io, path_a, .{});
    file_a.close(io);
    var file_b = try cwd.openFile(io, path_b, .{});
    file_b.close(io);
}

test "runPipeline: multi-target path collision and content overlap exit 2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const shared = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-collide", .{tmp.sub_path});
    defer gpa.free(shared);

    // Equal output roots
    {
        var opts = Options{
            .mode = .html,
            .input_dir = "test/fixtures/html/content",
            .quiet = true,
        };
        try opts.targets.append(gpa, .{ .name = "a", .output_dir = shared });
        try opts.targets.append(gpa, .{ .name = "b", .output_dir = shared });
        defer opts.targets.deinit(gpa);
        try std.testing.expectEqual(ExitCode.usage, runPipeline(io, gpa, opts));
    }

    // Workspace escape
    {
        var opts = Options{
            .mode = .html,
            .input_dir = "test/fixtures/html/content",
            .quiet = true,
        };
        try opts.targets.append(gpa, .{ .name = "escaped", .output_dir = "../outside-boris-target" });
        defer opts.targets.deinit(gpa);
        try std.testing.expectEqual(ExitCode.usage, runPipeline(io, gpa, opts));
    }

    // Content root overlap
    {
        var opts = Options{
            .mode = .html,
            .input_dir = "test/fixtures/html/content",
            .quiet = true,
        };
        try opts.targets.append(gpa, .{ .name = "bad", .output_dir = "test/fixtures/html/content" });
        defer opts.targets.deinit(gpa);
        try std.testing.expectEqual(ExitCode.usage, runPipeline(io, gpa, opts));
    }
}

test "parseOptions: HTML mode defaults and exclusive dirs" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--html" });
    defer o.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.html, o.mode);
    try std.testing.expectEqualStrings("dist", o.html_dir.?);
    try std.testing.expect(o.out_dir == null);
    try std.testing.expect(o.rag_dir == null);

    // Bare argv defaults to HTML (Feature 2).
    var bare = try parseOptions(std.testing.allocator, &.{"boris"});
    defer bare.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.html, bare.mode);
    try std.testing.expectEqualStrings("dist", bare.html_dir.?);

    // Explicit --out selects IR (not HTML).
    var ir = try parseOptions(std.testing.allocator, &.{ "boris", "--out", ".boris" });
    defer ir.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.ir, ir.mode);
    try std.testing.expectEqualStrings(".boris", ir.out_dir.?);
    try std.testing.expect(ir.html_dir == null);

    try std.testing.expectError(
        error.ConflictingFlags,
        parseOptions(std.testing.allocator, &.{ "boris", "--html", "--out", ".boris" }),
    );
    try std.testing.expectError(
        error.ConflictingFlags,
        parseOptions(std.testing.allocator, &.{ "boris", "--html-dir", "d", "--rag" }),
    );
}

test {
    _ = @import("watch.zig");
}
