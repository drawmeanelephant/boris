//! Boris — product CLI entry (IR + optional RAG + opt-in HTML).
//!
//! Typed flag parsing + exit-code model. IR mode runs the content compiler
//! pipeline (scan → parse → PageDb → graph validate → deterministic JSON IR).
//! RAG mode reuses `pipeline.compile` + exports a deterministic corpus.
//! HTML mode calls the Apex + Whiteboard site compiler under `dist/` (opt-in).

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const diagnostic = @import("diagnostic.zig");
const pipeline = @import("pipeline.zig");
const rag = @import("rag.zig");
const compile = @import("compile.zig");
const target = @import("target.zig");

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
    switch (opts.mode) {
        .rag => return runRag(io, gpa, opts),
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

/// Opt-in HTML site render via Apex C-ABI + whiteboard arena (compile path).
pub fn runHtml(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const html_dir = opts.html_dir orelse default_html;

    if (opts.watch) {
        const watch = @import("watch.zig");
        var watcher = watch.PollingWatcher.init(gpa, io);
        defer watcher.deinit();

        watcher.addRoot(opts.input_dir) catch |err| {
            return mapHtmlError(err, opts.quiet);
        };
        const layout_dir = std.fs.path.dirname(default_layout) orelse ".";
        watcher.addRoot(layout_dir) catch |err| {
            return mapHtmlError(err, opts.quiet);
        };

        var coord = watch.WatchCoordinator.init(gpa, io, opts, watcher.watcher()) catch |err| {
            return mapHtmlError(err, opts.quiet);
        };
        defer coord.deinit();

        coord.run() catch |err| {
            return mapHtmlError(err, opts.quiet);
        };

        return .success;
    }

    if (opts.targets.items.len > 0) {
        compile.compileHtmlSiteMulti(io, gpa, opts.targets.items, .{
            .content_root = opts.input_dir,
            .layout_path = default_layout,
            .incremental = opts.incremental,
            .quiet = opts.quiet,
            .jobs = opts.jobs,
        }) catch |err| {
            return mapHtmlError(err, opts.quiet);
        };

        if (!opts.quiet) {
            std.debug.print("ok: wrote HTML for {d} target(s)\n", .{ opts.targets.items.len });
        }
    } else {
        const stats = compile.compileHtmlSite(io, gpa, .{
            .content_root = opts.input_dir,
            .dist_dir = html_dir,
            .layout_path = default_layout,
            .incremental = opts.incremental,
            .quiet = opts.quiet,
            .jobs = opts.jobs,
        }) catch |err| {
            return mapHtmlError(err, opts.quiet);
        };

        if (!opts.quiet) {
            std.debug.print("ok: wrote HTML under {s} ({d} page(s))\n", .{ html_dir, stats.pages_written });
        }
    }
    return .success;
}

/// Map HTML compile failures to process exit codes.
/// Content/layout/component faults → 1; missing content root and I/O → 3.
/// When `quiet`, skip stderr text (exit code and artifacts still convey failure).
fn mapHtmlError(err: anyerror, quiet: bool) ExitCode {
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
            }
            return .usage;
        },
        error.ParseFailed,
        error.ComponentFailed,
        error.LayoutMissingMarker,
        error.LayoutDuplicateMarker,
        error.MultiTargetCompilationFailed,
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


test "parseOptions: HTML mode defaults and exclusive dirs" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--html" });
    defer o.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.html, o.mode);
    try std.testing.expectEqualStrings("dist", o.html_dir.?);
    try std.testing.expect(o.out_dir == null);
    try std.testing.expect(o.rag_dir == null);

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
