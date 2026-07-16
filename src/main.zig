//! Boris — product CLI entry (HTML default + IR + optional RAG).
//!
//! Typed flag parsing + exit-code model. Default mode builds an HTML site
//! under `dist/` (Apex + Whiteboard + layout splice). IR mode (`--out` /
//! `--no-rag`) runs the content compiler pipeline (scan → parse → PageDb →
//! graph validate → deterministic JSON IR). RAG mode reuses `pipeline.compile`
//! + exports a deterministic corpus.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const diagnostic = @import("diagnostic.zig");
const pipeline = @import("pipeline.zig");
const rag = @import("rag.zig");
const context = @import("context.zig");
const compile = @import("compile.zig");
const target = @import("target.zig");
const intelligence = @import("intelligence.zig");
const json_out = @import("json_out.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const Options = cli.Options;
pub const Mode = cli.Mode;
pub const parseOptions = cli.parseOptions;

const default_out = ".boris";
const default_rag = "rag";
const default_html = "dist";
const default_layout = "layouts/main.html";

/// Production runner: help text + IR / RAG / HTML pipelines.
const ProdRunner = struct {
    gpa: std.mem.Allocator,
    io: Io,

    pub fn printHelp(_: *const @This()) void {
        cli.printUsage();
    }

    pub fn reportUsage(_: *const @This(), err: cli.ParseError, bad_arg: ?[]const u8) void {
        cli.printParseError(err, bad_arg);
        cli.printUsage();
    }

    pub fn run(self: *const @This(), opts: Options) ExitCode {
        return runPipeline(self.io, self.gpa, opts);
    }
};

/// Map pipeline result to process exit code.
///
/// - validation / content errors → 1
/// - usage errors are handled before this (exit 2)
/// - I/O / system errors → 3
pub fn runPipeline(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    if (opts.command != .build) return runIntelligence(io, gpa, opts);
    switch (opts.mode) {
        .rag => return runRag(io, gpa, opts),
        .context => return runContext(io, gpa, opts),
        .html => return runHtml(io, gpa, opts),
        .ir => {},
    }

    const out_dir = opts.out_dir orelse default_out;

    var result = pipeline.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        if (!opts.quiet) {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        }
        return .io_error;
    };
    defer result.deinit();

    if (result.diagnostics.items.len > 0 and !opts.quiet) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items) catch {
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

/// Deterministic provenance-rich AI context export (same compile + graph validation as IR/RAG).
pub fn runContext(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const context_dir = opts.context_dir orelse "context";

    var result = context.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = context_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        if (!opts.quiet) {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        }
        return .io_error;
    };
    defer result.deinit();

    if (result.compile.diagnostics.items.len > 0 and !opts.quiet) {
        pipeline.printDiagnostics(gpa, result.compile.diagnostics.items) catch {
            return .io_error;
        };
    }

    if (result.ok()) {
        if (!opts.quiet) {
            std.debug.print("ok: wrote context bundle under {s} ({d} page(s))\n", .{ context_dir, result.compile.pages.items.len });
        }
        return .success;
    }

    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Read-only graph analysis. This intentionally calls pipeline.compile rather
/// than pipeline.run, so no IR/RAG/HTML artifacts or cache manifests publish.
pub fn runIntelligence(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    var result = pipeline.compile(io, gpa, .{
        .content_root = opts.input_dir,
        .quiet = true,
    }) catch |err| {
        if (!opts.quiet) std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (!result.ok) {
        if (!opts.quiet) pipeline.printDiagnostics(gpa, result.diagnostics.items) catch return .io_error;
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
            if (!opts.quiet) std.debug.print("error: impact target not found: {s}\n", .{id});
            return .usage;
        }
        if (requested == null) requested = .{ .type = .source, .value = id };
    }

    var report = intelligence.analyze(gpa, pages.items, edges.items, .{ .impact = requested }) catch |err| {
        if (!opts.quiet) std.debug.print("error: analysis failed: {s}\n", .{@errorName(err)});
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
            if (!opts.quiet) std.debug.print("error: failed to write report {s}: {s}\n", .{ path, @errorName(err) });
            return .io_error;
        };
    } else {
        std.debug.print("{s}", .{rendered});
    }

    // `check` is CI-useful by default: unreferenced pages are findings.
    if (opts.command == .check and report.summary.unreferenced_pages > 0) return .content_error;
    return .success;
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
    try w.writeAll("{\n  \"format\": \"boris-documentation-intelligence\",\n  \"schemaVersion\": \"0.1.0\",\n  \"compiler\": \"boris/0.3.1\",\n  \"input\": ");
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
    try w.writeAll("\n  },\n  \"pages\": [");
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
        fn less(_: void, a: []const u8, b: []const u8) bool { return std.mem.order(u8, a, b) == .lt; }
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
    try w.writeAll("\n}\n");
    return out.toOwnedSlice(gpa);
}

/// Optional deterministic RAG export (same compile + graph.validate as IR).
pub fn runRag(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const rag_dir = opts.rag_dir orelse default_rag;

    var result = rag.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = rag_dir,
        .system_docs_dir = "docs/rag/system",
        .quiet = opts.quiet,
    }) catch |err| {
        if (!opts.quiet) {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        }
        return .io_error;
    };
    defer result.deinit();

    if (result.diagnostics().len > 0 and !opts.quiet) {
        pipeline.printDiagnostics(gpa, result.diagnostics()) catch {
            return .io_error;
        };
    }

    if (result.ok()) {
        if (!opts.quiet) {
            std.debug.print("ok: wrote RAG under {s} ({d} page(s))\n", .{ rag_dir, result.stats.content_pages });
        }
        return .success;
    }

    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// HTML site render via Apex C-ABI + whiteboard arena (default CLI path).
pub fn runHtml(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const html_dir = opts.html_dir orelse default_html;

    const layout_path = opts.html_layout;

    if (opts.watch) {
        const watch = @import("watch.zig");
        var watcher = watch.PollingWatcher.init(gpa, io);
        defer watcher.deinit();

        watcher.addRoot(opts.input_dir) catch |err| {
            return mapHtmlError(err, opts.quiet, opts.targets.items, layout_path);
        };

        // Watch unique layout parent directories (global + per-target overrides).
        var layout_roots: std.StringHashMapUnmanaged(void) = .{};
        defer layout_roots.deinit(gpa);
        const add_layout_root = struct {
            fn go(w: *watch.PollingWatcher, map: *std.StringHashMapUnmanaged(void), gpa_: std.mem.Allocator, lp: []const u8, input_dir: []const u8) !void {
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
            return mapHtmlError(err, opts.quiet, opts.targets.items, layout_path);
        };
        for (opts.targets.items) |t| {
            if (t.layout_path) |lp| {
                add_layout_root(&watcher, &layout_roots, gpa, lp, opts.input_dir) catch |err| {
                    return mapHtmlError(err, opts.quiet, opts.targets.items, layout_path);
                };
            }
        }

        var coord = watch.WatchCoordinator.init(gpa, io, opts, watcher.watcher()) catch |err| {
            return mapHtmlError(err, opts.quiet, opts.targets.items, layout_path);
        };
        defer coord.deinit();

        coord.run() catch |err| {
            return mapHtmlError(err, opts.quiet, opts.targets.items, layout_path);
        };

        return .success;
    }

    if (opts.targets.items.len > 0) {
        compile.compileHtmlSiteMulti(io, gpa, opts.targets.items, .{
            .content_root = opts.input_dir,
            .layout_path = layout_path,
            .incremental = opts.incremental,
            .quiet = opts.quiet,
            .jobs = opts.jobs,
        }) catch |err| {
            return mapHtmlError(err, opts.quiet, opts.targets.items, layout_path);
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
        }) catch |err| {
            return mapHtmlError(err, opts.quiet, &.{}, layout_path);
        };

        if (!opts.quiet) {
            std.debug.print("ok: wrote HTML under {s} ({d} page(s))\n", .{ html_dir, stats.pages_written });
        }
    }
    return .success;
}

/// Map HTML compile failures to process exit codes.
/// Target configuration / path isolation → 2; content/layout/component → 1;
/// missing content root and I/O → 3. When `quiet`, skip stderr text (exit codes
/// and artifacts still convey failure).
fn mapHtmlError(
    err: anyerror,
    quiet: bool,
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
        => {
            if (!quiet) {
                std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
                if (targets.len > 0) {
                    std.debug.print("configured targets (canonical order):\n", .{});
                    target.printTargetConfigLines(targets, global_layout);
                }
            }
            return .usage;
        },
        // Graph/include/wiki (and multi-target wrap of those) already print
        // structured diagnostics on the HTML path; re-printing @errorName only doubles noise.
        error.GraphValidationFailed,
        error.IncludeFailed,
        error.ReferenceFailed,
        // Multi-target wrap can mix content and I/O; prefer content for graph/include
        // failures already printed, but treat pure layout load I/O as exit 3 via FileNotFound etc.
        error.MultiTargetCompilationFailed,
        => return .content_error,
        error.MultiTargetIoFailed => {
            if (!quiet) {
                std.debug.print("error: one or more HTML targets failed due to I/O or a system error\n", .{});
            }
            return .io_error;
        },
        error.ParseFailed,
        error.ComponentFailed,
        error.LayoutMissingMarker,
        error.LayoutDuplicateMarker,
        error.LayoutUnknownMarker,
        error.LayoutInvalidAssetUrl,
        error.LayoutInvalidUtf8,
        error.AssetNotFound,
        error.AssetCollision,
        error.AssetSymlink,
        error.AssetPathEscape,
        error.ThemeRootMissing,
        error.InvalidThemePath,
        error.ThemeSymlink,
        error.FooterSymlink,
        => {
            if (!quiet) {
                std.debug.print("error: content or layout failure: {s}\n", .{@errorName(err)});
            }
            return .content_error;
        },
        else => {
            if (!quiet) {
                std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
            }
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

/// Silent runner for CLI-only tests: no help/usage/pipeline I/O.
const SilentRunner = struct {
    pipeline_calls: usize = 0,

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
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.MultiTargetIoFailed, true, &.{}, default_layout));
}

test "mapHtmlError: target configuration failures exit 2" {
    const specs = [_]target.TargetSpec{
        .{ .name = "prod", .output_dir = "dist/prod" },
    };
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.TargetOutputCollision, true, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.WorkspaceEscape, true, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.DuplicateTargetName, true, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.InvalidTargetName, true, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.TargetOutputSymlink, true, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.EmptyTargetDirectory, true, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.NoTargetsSpecified, true, &.{}, default_layout));
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

    // Uses repo `layouts/main.html` (default_layout) + HTML content fixture.
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
