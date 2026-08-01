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
            }) catch |err| return reportError(err);
            std.debug.print("republished clean Boris fixture: {s}\n", .{options.fixture});
            return @intFromEnum(ExitCode.success);
        },
    }
}

fn parseOptions(allocator: std.mem.Allocator, args: []const [:0]const u8) ParseError!Options {
    if (args.len < 2) return error.MissingCommand;
    const command = parseCommand(args[1]) orelse if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) return .{ .command = .generate, .help = true } else return error.UnknownCommand;
    var options = Options{ .command = command };
    var barbs: std.ArrayList([]const u8) = .empty;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
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
        } else {
            return error.UnknownFlag;
        }
    }
    options.barb_names = try barbs.toOwnedSlice(allocator);
    if (options.command == .generate and options.output.len == 0) return error.MissingOutput;
    if ((options.command == .validate or options.command == .inspect or options.command == .run or options.command == .republish_clean) and options.fixture.len == 0 and options.output.len == 0) return error.MissingFixture;
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

fn printUsage() void {
    std.debug.print(
        \\boris-testdata — deterministic Boris fixture generator and evidence runner
        \\
        \\Usage:
        \\  boris-testdata generate --pages N --seed U64 --profile NAME --output DIR [options]
        \\  boris-testdata validate --fixture DIR [--format human|json]
        \\  boris-testdata inspect --input DIR [--format human|json]
        \\  boris-testdata run --fixture DIR --boris PATH
        \\  boris-testdata republish-clean --fixture DIR --boris PATH
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
