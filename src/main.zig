//! Boris — product CLI entry (milestone 3).
//!
//! Typed flag parsing + exit-code model. Content pipelines are not wired yet:
//! valid build modes print a controlled "pipeline not implemented" stub and
//! exit 0 until later milestones.

const std = @import("std");
const cli = @import("cli.zig");
const diagnostic = @import("diagnostic.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const Options = cli.Options;
pub const Mode = cli.Mode;
pub const parseOptions = cli.parseOptions;

/// Production runner: help text + not-yet-implemented pipeline stub.
/// Methods are `pub` so `cli.execute` can call them via `anytype` across modules.
const ProdRunner = struct {
    pub fn printHelp(_: *const @This()) void {
        cli.printUsage();
    }

    pub fn reportUsage(_: *const @This(), err: cli.ParseError, bad_arg: ?[]const u8) void {
        cli.printParseError(err, bad_arg);
        cli.printUsage();
    }

    pub fn run(_: *const @This(), opts: Options) ExitCode {
        return runPipelineStub(opts).exitCode();
    }
};

/// Stub until milestone 6 wires discovery / IR / RAG. Never scans content.
pub fn runPipelineStub(opts: Options) diagnostic.RunResult {
    if (!opts.quiet) {
        switch (opts.mode) {
            .ir => std.debug.print(
                "pipeline not implemented (IR mode; input={s}, out={s})\n",
                .{ opts.input_dir, opts.out_dir orelse default_out },
            ),
            .rag => std.debug.print(
                "pipeline not implemented (RAG mode; input={s}, rag-dir={s})\n",
                .{ opts.input_dir, opts.rag_dir orelse default_rag },
            ),
        }
    }
    return diagnostic.RunResult.success();
}

const default_out = ".boris";
const default_rag = "rag";

/// Pure dispatch used by `main` and tests (no `std.process.Init` required).
pub fn runArgs(args: []const []const u8) u8 {
    const runner: ProdRunner = .{};
    return cli.runArgs(args, &runner);
}

/// Zig 0.16 entry: main receives `std.process.Init` (gpa, arena, io, …).
pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();

    const args_z = init.minimal.args.toSlice(cold) catch {
        std.debug.print("error: failed to read process arguments\n", .{});
        return ExitCode.io_error.int();
    };

    // toSlice yields [:0]const u8; parseOptions wants []const []const u8.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(cold);
    args_list.ensureTotalCapacity(cold, args_z.len) catch {
        std.debug.print("error: out of memory parsing arguments\n", .{});
        return ExitCode.io_error.int();
    };
    for (args_z) |a| {
        args_list.appendAssumeCapacity(a);
    }

    return runArgs(args_list.items);
}

// --- main-level exit-code mapping tests ------------------------------------

/// Silent runner for tests: no help/usage/stub I/O.
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

    // Help → 0, never runs pipeline
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--help" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "-h" }, &runner));
    try std.testing.expectEqual(@as(usize, 0), runner.pipeline_calls);

    // Valid build modes → 0
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{"boris"}, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--quiet" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--no-rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--rag-dir", "x" }, &runner));
    try std.testing.expect(runner.pipeline_calls >= 5);

    // Usage → 2, still no extra pipeline
    const before = runner.pipeline_calls;
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--rag", "--no-rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--rag", "--out", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--no-rag", "--rag-dir", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--unknown" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--input" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "positional" }, &runner));
    try std.testing.expectEqual(before, runner.pipeline_calls);
}

test "runPipelineStub: success and quiet" {
    const r = runPipelineStub(.{
        .mode = .ir,
        .input_dir = "content",
        .out_dir = ".boris",
        .rag_dir = null,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.success, r.exitCode());
}

test "ExitCode contract surface" {
    try std.testing.expectEqual(@as(u8, 0), ExitCode.success.int());
    try std.testing.expectEqual(@as(u8, 1), ExitCode.content_error.int());
    try std.testing.expectEqual(@as(u8, 2), ExitCode.usage.int());
    try std.testing.expectEqual(@as(u8, 3), ExitCode.io_error.int());
}
