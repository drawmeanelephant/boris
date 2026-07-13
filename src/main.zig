//! Boris — early CLI stub (milestone 1).
//!
//! Accepted flags: `--help` / `-h` only.
//! Does not scan the filesystem or run any content pipeline.

const std = @import("std");

/// Process exit codes for the milestone-1 CLI surface.
pub const ExitCode = enum(u8) {
    success = 0,
    usage = 2,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub const Options = struct {
    /// When true, print help and exit successfully.
    help: bool = false,
};

pub const ParseError = error{
    UnknownFlag,
};

/// Parse argv into `Options`. Does not print or exit.
///
/// `args[0]` is the program name when present (skipped).
/// Only `--help` and `-h` are accepted. Any other argument is `error.UnknownFlag`.
pub fn parseOptions(args: []const []const u8) ParseError!Options {
    var opts: Options = .{};

    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            opts.help = true;
            // Help short-circuits: remaining flags are not required for success.
            return opts;
        } else {
            return error.UnknownFlag;
        }
    }

    return opts;
}

fn printUsage() void {
    std.debug.print(
        \\Boris — early Zig project foundation (milestone 1)
        \\
        \\Usage: boris [--help | -h]
        \\
        \\  -h, --help    Show this help and exit 0
        \\
        \\No other flags are accepted yet. Exit codes: 0 success, 2 usage.
        \\
    , .{});
}

fn logUsage(err: ParseError, bad_arg: ?[]const u8) void {
    switch (err) {
        error.UnknownFlag => {
            if (bad_arg) |a| {
                std.log.err("unknown argument: {s} (try --help)", .{a});
            } else {
                std.log.err("unknown argument (try --help)", .{});
            }
        },
    }
    printUsage();
}

/// Zig 0.16 entry: main receives `std.process.Init` (gpa, arena, io, …).
pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();

    const args_z = init.minimal.args.toSlice(cold) catch {
        std.log.err("failed to read process arguments", .{});
        return ExitCode.usage.int();
    };

    // toSlice yields [:0]const u8; parseOptions wants []const []const u8.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(cold);
    args_list.ensureTotalCapacity(cold, args_z.len) catch {
        std.log.err("out of memory parsing arguments", .{});
        return ExitCode.usage.int();
    };
    for (args_z) |a| {
        args_list.appendAssumeCapacity(a);
    }

    const opts = parseOptions(args_list.items) catch |err| {
        if (err == error.UnknownFlag) {
            var i: usize = if (args_list.items.len > 0) 1 else 0;
            while (i < args_list.items.len) : (i += 1) {
                const a = args_list.items[i];
                if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) continue;
                logUsage(err, a);
                return ExitCode.usage.int();
            }
        }
        logUsage(err, null);
        return ExitCode.usage.int();
    };

    // Bare invocation (no flags) or explicit help: print usage and exit 0.
    // Does not touch the filesystem.
    _ = opts.help;
    printUsage();
    return ExitCode.success.int();
}

// --- CLI unit tests --------------------------------------------------------

test "parseOptions: bare invocation is ok (no flags)" {
    const opts = try parseOptions(&.{"boris"});
    try std.testing.expect(!opts.help);
}

test "parseOptions: --help and -h set help" {
    const opts = try parseOptions(&.{ "boris", "--help" });
    try std.testing.expect(opts.help);

    const opts2 = try parseOptions(&.{ "boris", "-h" });
    try std.testing.expect(opts2.help);
}

test "parseOptions: help short-circuits remaining args" {
    // --help wins even if junk follows (usage path never sees the junk).
    const opts = try parseOptions(&.{ "boris", "--help", "--not-a-real-flag" });
    try std.testing.expect(opts.help);
}

test "parseOptions: unknown flag is usage error" {
    try std.testing.expectError(error.UnknownFlag, parseOptions(&.{ "boris", "--unknown" }));
    try std.testing.expectError(error.UnknownFlag, parseOptions(&.{ "boris", "--wat" }));
    try std.testing.expectError(error.UnknownFlag, parseOptions(&.{ "boris", "content" }));
}

test "ExitCode values" {
    try std.testing.expectEqual(@as(u8, 0), ExitCode.success.int());
    try std.testing.expectEqual(@as(u8, 2), ExitCode.usage.int());
}
