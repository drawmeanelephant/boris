const std = @import("std");
const generator = @import("generator.zig");
const validator = @import("validator.zig");

const Io = std.Io;

const ExitCode = enum(u8) {
    success = 0,
    content_failure = 1,
    usage = 2,
    system_failure = 3,
};

const Command = enum { generate, validate, inspect, run, republish_clean };
const Format = enum { human, json };

const Options = struct {
    command: Command,
    pages: usize = 24,
    seed: u64 = 20260801,
    profile: []const u8 = "readme-realistic-v1",
    output: []const u8 = "results/fixture",
    fixture: []const u8 = "",
    boris: []const u8 = "./zig-out/bin/boris",
    theme: ?[]const u8 = null,
    template: ?[]const u8 = null,
    format: Format = .human,
    force: bool = false,
    help: bool = false,
    jobs: usize = 1,
    barb_names: []const []const u8 = &.{},
};

const ParseError = error{
    MissingCommand,
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    InvalidPageCount,
    InvalidSeed,
    InvalidFormat,
    InvalidJobs,
    DuplicateJobs,
    JobsNotAllowed,
    MissingFixture,
    MissingOutput,
    OutOfMemory,
};

pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();
    const args_z = init.minimal.args.toSlice(cold) catch {
        std.debug.print("boris-testdata: unable to read process arguments\n", .{});
        return @intFromEnum(ExitCode.usage);
    };
    const options = parseOptions(cold, args_z) catch |err| {
        std.debug.print("boris-testdata: {s}\n", .{@errorName(err)});
        printUsage();
        return @intFromEnum(ExitCode.usage);
    };
    if (options.help) {
        printUsage();
        return @intFromEnum(ExitCode.success);
    }

    switch (options.command) {
        .generate => {
            var result = generator.generate(.{
                .io = init.io,
                .allocator = init.gpa,
                .output_path = options.output,
                .pages = options.pages,
                .seed = options.seed,
                .profile_selector = options.profile,
                .barb_names = options.barb_names,
                .theme_path = options.theme,
                .template_path = options.template,
                .force = options.force,
            }) catch |err| return reportError(err);
            defer init.gpa.free(result.assignments);
            defer result.profile.deinit(init.gpa);
            std.debug.print("generated fixture: {s} pages={d} profile={s} barbs={d}\n", .{
                result.output_path,
                result.page_count,
                result.profile.name,
                result.assignments.len,
            });
            return @intFromEnum(ExitCode.success);
        },
        .validate, .inspect => {
            if (options.fixture.len == 0) {
                std.debug.print("boris-testdata: --fixture is required\n", .{});
                return @intFromEnum(ExitCode.usage);
            }
            const report = validator.validate(init.io, init.gpa, options.fixture) catch |err| return reportError(err);
            defer {
                var owned_report = report;
                owned_report.deinit(init.gpa);
            }
            printReport(report, options.format, options.command == .inspect);
            return if (report.ok) @intFromEnum(ExitCode.success) else @intFromEnum(ExitCode.content_failure);
        },
        .run => {
            if (options.fixture.len == 0) {
                std.debug.print("boris-testdata: --fixture is required for run\n", .{});
                return @intFromEnum(ExitCode.usage);
            }
            generator.runFixture(.{
                .io = init.io,
                .allocator = init.gpa,
                .fixture_path = options.fixture,
                .boris_path = options.boris,
                .jobs = options.jobs,
            }) catch |err| return reportError(err);
            std.debug.print("ran Boris fixture: {s}\n", .{options.fixture});
            return @intFromEnum(ExitCode.success);
        },
        .republish_clean => {
            if (options.fixture.len == 0) {
                std.debug.print("boris-testdata: --fixture is required for republish-clean\n", .{});
                return @intFromEnum(ExitCode.usage);
            }
            generator.republishCleanFixture(.{
                .io = init.io,
                .allocator = init.gpa,
                .fixture_path = options.fixture,
                .boris_path = options.boris,
                .jobs = options.jobs,
            }) catch |err| return reportError(err);
            std.debug.print("republished clean Boris fixture: {s}\n", .{options.fixture});
            return @intFromEnum(ExitCode.success);
        },
    }
}

fn parseOptions(allocator: std.mem.Allocator, args: []const [:0]const u8) ParseError!Options {
    if (args.len < 2) return error.MissingCommand;
    // Help genuinely wins regardless of argument position and of malformed or
    // missing option values: honor `-h`/`--help` before validating anything
    // else, so `run --jobs abc --help` prints help rather than a usage error.
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .{ .command = .generate, .help = true };
        }
    }
    const command = parseCommand(args[1]) orelse return error.UnknownCommand;
    var options = Options{ .command = command };
    var barbs: std.ArrayList([]const u8) = .empty;
    var saw_jobs = false;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.startsWith(u8, arg, "--pages=")) {
            options.pages = parsePageCount(arg["--pages=".len..]) catch return error.InvalidPageCount;
        } else if (std.mem.eql(u8, arg, "--pages")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.pages = parsePageCount(args[index]) catch return error.InvalidPageCount;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            options.seed = std.fmt.parseInt(u64, arg["--seed=".len..], 10) catch return error.InvalidSeed;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.seed = std.fmt.parseInt(u64, args[index], 10) catch return error.InvalidSeed;
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            options.profile = arg["--profile=".len..];
        } else if (std.mem.eql(u8, arg, "--profile")) {
            options.profile = try nextValue(args, &index);
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            options.output = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--output")) {
            options.output = try nextValue(args, &index);
        } else if (std.mem.startsWith(u8, arg, "--fixture=")) {
            options.fixture = arg["--fixture=".len..];
        } else if (std.mem.eql(u8, arg, "--fixture") or std.mem.eql(u8, arg, "--input")) {
            options.fixture = try nextValue(args, &index);
        } else if (std.mem.startsWith(u8, arg, "--boris=")) {
            options.boris = arg["--boris=".len..];
        } else if (std.mem.eql(u8, arg, "--boris")) {
            options.boris = try nextValue(args, &index);
        } else if (std.mem.startsWith(u8, arg, "--theme=")) {
            options.theme = arg["--theme=".len..];
        } else if (std.mem.eql(u8, arg, "--theme")) {
            options.theme = try nextValue(args, &index);
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            options.template = arg["--template=".len..];
        } else if (std.mem.eql(u8, arg, "--template")) {
            options.template = try nextValue(args, &index);
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            options.format = parseFormat(arg["--format=".len..]) orelse return error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--format")) {
            options.format = parseFormat(try nextValue(args, &index)) orelse return error.InvalidFormat;
        } else if (std.mem.startsWith(u8, arg, "--barb=") or std.mem.startsWith(u8, arg, "--poison=")) {
            const prefix_len = if (std.mem.startsWith(u8, arg, "--barb=")) "--barb=".len else "--poison=".len;
            try barbs.append(allocator, arg[prefix_len..]);
        } else if (std.mem.eql(u8, arg, "--barb") or std.mem.eql(u8, arg, "--poison")) {
            try barbs.append(allocator, try nextValue(args, &index));
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            if (saw_jobs) return error.DuplicateJobs;
            saw_jobs = true;
            options.jobs = parseJobs(arg["--jobs=".len..]) catch return error.InvalidJobs;
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            if (saw_jobs) return error.DuplicateJobs;
            saw_jobs = true;
            options.jobs = parseJobs(try nextValue(args, &index)) catch return error.InvalidJobs;
        } else {
            return error.UnknownFlag;
        }
    }
    options.barb_names = try barbs.toOwnedSlice(allocator);
    if (options.command == .generate and options.output.len == 0) return error.MissingOutput;
    if ((options.command == .validate or options.command == .inspect or options.command == .run or options.command == .republish_clean) and options.fixture.len == 0 and options.output.len == 0) return error.MissingFixture;
    if (saw_jobs and !options.help and options.command != .run and options.command != .republish_clean) return error.JobsNotAllowed;
    return options;
}

fn nextValue(args: []const [:0]const u8, index: *usize) ParseError![]const u8 {
    index.* += 1;
    if (index.* >= args.len or args[index.*].len == 0) return error.MissingValue;
    return args[index.*];
}

fn parseCommand(value: []const u8) ?Command {
    if (std.mem.eql(u8, value, "generate")) return .generate;
    if (std.mem.eql(u8, value, "validate")) return .validate;
    if (std.mem.eql(u8, value, "inspect")) return .inspect;
    if (std.mem.eql(u8, value, "run")) return .run;
    if (std.mem.eql(u8, value, "republish-clean")) return .republish_clean;
    return null;
}

fn parseFormat(value: []const u8) ?Format {
    if (std.mem.eql(u8, value, "human")) return .human;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

fn parsePageCount(value: []const u8) !usize {
    const count = try std.fmt.parseInt(usize, value, 10);
    if (count == 0) return error.InvalidPageCount;
    return count;
}

/// Parse a `--jobs` value. The valid range matches the Boris compiler
/// (`generator.min_jobs`..`generator.max_jobs`, i.e. 1..64). Zero,
/// out-of-range, empty, and malformed values are usage errors. Delegates to
/// `generator.validateJobs` so the CLI parser and both fixture operations
/// share a single source of truth for the range.
fn parseJobs(value: []const u8) !usize {
    const count = std.fmt.parseInt(usize, value, 10) catch return error.InvalidJobs;
    try generator.validateJobs(count);
    return count;
}

fn printUsage() void {
    std.debug.print(
        \\boris-testdata — deterministic Boris fixture generator and evidence runner
        \\
        \\Usage:
        \\  boris-testdata generate --pages N --seed U64 --profile NAME --output DIR [options]
        \\  boris-testdata validate --fixture DIR [--format human|json]
        \\  boris-testdata inspect --input DIR [--format human|json]
        \\  boris-testdata run --fixture DIR --boris PATH [--jobs N]
        \\  boris-testdata republish-clean --fixture DIR --boris PATH [--jobs N]
        \\
        \\Run options:
        \\  --jobs N       Requested Boris parallel HTML workers (1–64; default 1)
        \\
        \\Generate options:
        \\  --pages N       Exact positive page count workload (default: 24)
        \\  --seed U64      Stable SplitMix-style seed (default: 20260801)
        \\  --profile NAME  readme-realistic-v1, mild-poison-v1, nightmare-v1, preserved-edge-v1, or JSON path
        \\  --barb NAME     Repeat to override profile barbs (alias: --poison)
        \\  --theme PATH    Copy an external Boris theme into optional-theme/
        \\  --template PATH Expand an external Markdown template into the page AST
        \\  --force         Replace the exact output directory if it exists
        \\
        \\The generator owns only the requested output directory. It never shells
        \\out to create content or render Markdown. Post-publish barbs are applied
        \\by run after Boris writes results/boris-output.
        \\
    , .{});
}

fn printReport(report: validator.Report, format: Format, inspection: bool) void {
    if (format == .json) {
        std.debug.print("{{\"ok\":{s},\"fixture\":\"{s}\",\"profile\":\"{s}\",\"pages\":{d},\"files\":{d},\"bytes\":{d},\"expectedExitCode\":{d},\"barbs\":{d},\"surfaceErrors\":{d},\"graphErrors\":{d},\"error\":\"{s}\"}}\n", .{
            if (report.ok) "true" else "false",
            report.fixture,
            report.profile,
            report.page_count,
            report.listed_files,
            report.total_bytes,
            report.expected_exit_code,
            report.barb_count,
            report.surface_errors,
            report.graph_errors,
            report.error_message,
        });
    } else if (report.ok) {
        std.debug.print("{s}: ok profile={s} pages={d} files={d} bytes={d} expected_exit={d} barbs={d} surface_errors={d} graph_errors={d}\n", .{
            if (inspection) "inspect" else "validate",
            report.profile,
            report.page_count,
            report.listed_files,
            report.total_bytes,
            report.expected_exit_code,
            report.barb_count,
            report.surface_errors,
            report.graph_errors,
        });
    } else {
        std.debug.print("validate: failed: {s}\n", .{report.error_message});
    }
}

test "page count parser accepts positive usize workloads without a named ceiling" {
    try std.testing.expectEqual(@as(usize, 1_000_001), try parsePageCount("1000001"));
    try std.testing.expectError(error.InvalidPageCount, parsePageCount("0"));
}

fn reportError(err: anyerror) u8 {
    std.debug.print("boris-testdata: failed: {s}\n", .{@errorName(err)});
    return switch (err) {
        error.BorisExpectationMismatch => @intFromEnum(ExitCode.content_failure),
        error.InvalidFixture, error.OutputExists, error.ProfileNotFound, error.InvalidProfile => @intFromEnum(ExitCode.content_failure),
        error.InvalidPageCount, error.InvalidSeed, error.InvalidOutputPath, error.UnknownBarb, error.IncompatibleBarbCombination => @intFromEnum(ExitCode.usage),
        else => @intFromEnum(ExitCode.system_failure),
    };
}

test "jobs parser accepts the Boris range and rejects invalid values" {
    try std.testing.expectEqual(@as(usize, 1), try parseJobs("1"));
    try std.testing.expectEqual(@as(usize, 64), try parseJobs("64"));
    try std.testing.expectEqual(@as(usize, 4), try parseJobs("4"));
    try std.testing.expectError(error.InvalidJobs, parseJobs("0"));
    try std.testing.expectError(error.InvalidJobs, parseJobs("65"));
    try std.testing.expectError(error.InvalidJobs, parseJobs(""));
    try std.testing.expectError(error.InvalidJobs, parseJobs("abc"));
    try std.testing.expectError(error.InvalidJobs, parseJobs("4x"));
    try std.testing.expectError(error.InvalidJobs, parseJobs("-1"));
}

test "help wins regardless of argument position and malformed jobs values" {
    // `--help` after a malformed jobs value must not fail parsing.
    const after = try parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs", "abc", "--help",
    });
    defer std.testing.allocator.free(after.barb_names);
    try std.testing.expect(after.help);

    // `--help` before a malformed jobs value.
    const before = try parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--help", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs", "0",
    });
    defer std.testing.allocator.free(before.barb_names);
    try std.testing.expect(before.help);

    // `--help` with a missing jobs value.
    const missing = try parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs", "--help",
    });
    defer std.testing.allocator.free(missing.barb_names);
    try std.testing.expect(missing.help);
}

test "CLI parser accepts jobs for run and republish-clean in both forms" {
    const args = [_][:0]const u8{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs", "4",
    };
    const options = try parseOptions(std.testing.allocator, &args);
    defer std.testing.allocator.free(options.barb_names);
    try std.testing.expectEqual(@as(usize, 4), options.jobs);
    try std.testing.expectEqual(Command.run, options.command);

    const joined = [_][:0]const u8{
        "boris-testdata", "republish-clean", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs=64",
    };
    const options2 = try parseOptions(std.testing.allocator, &joined);
    defer std.testing.allocator.free(options2.barb_names);
    try std.testing.expectEqual(@as(usize, 64), options2.jobs);
    try std.testing.expectEqual(Command.republish_clean, options2.command);
}

test "CLI parser defaults jobs to one for run" {
    const args = [_][:0]const u8{ "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris" };
    const options = try parseOptions(std.testing.allocator, &args);
    defer std.testing.allocator.free(options.barb_names);
    try std.testing.expectEqual(@as(usize, 1), options.jobs);
}

test "CLI parser rejects duplicate, missing, empty, and malformed jobs deterministically" {
    try std.testing.expectError(error.DuplicateJobs, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs", "2", "--jobs", "4",
    }));
    try std.testing.expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs",
    }));
    try std.testing.expectError(error.InvalidJobs, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs=",
    }));
    try std.testing.expectError(error.InvalidJobs, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs=0",
    }));
    try std.testing.expectError(error.InvalidJobs, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs", "65",
    }));
    try std.testing.expectError(error.InvalidJobs, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "run", "--fixture", "/tmp/f", "--boris", "./boris", "--jobs", "nope",
    }));
}

test "CLI parser rejects jobs for generate, validate, and inspect" {
    try std.testing.expectError(error.JobsNotAllowed, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "generate", "--output", "/tmp/out", "--jobs", "4",
    }));
    try std.testing.expectError(error.JobsNotAllowed, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "validate", "--fixture", "/tmp/f", "--jobs=2",
    }));
    try std.testing.expectError(error.JobsNotAllowed, parseOptions(std.testing.allocator, &.{
        "boris-testdata", "inspect", "--fixture", "/tmp/f", "--jobs", "8",
    }));
}

test "CLI parser accepts the documented generate shape" {
    const args = [_][:0]const u8{
        "boris-testdata",
        "generate",
        "--pages",
        "10000",
        "--seed=20260801",
        "--profile",
        "nightmare-v1",
        "--barb",
        "unsafe_markdown_link",
        "--output",
        "/private/tmp/corpus",
    };
    const options = try parseOptions(std.testing.allocator, &args);
    defer std.testing.allocator.free(options.barb_names);
    try std.testing.expectEqual(@as(usize, 10_000), options.pages);
    try std.testing.expectEqual(@as(u64, 20_260_801), options.seed);
    try std.testing.expectEqualStrings("nightmare-v1", options.profile);
    try std.testing.expectEqual(@as(usize, 1), options.barb_names.len);
}
