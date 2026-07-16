//! Opt-in synthetic scale smoke for Boris.
//!
//! This is deliberately outside build.zig and mandatory CI. It creates one
//! deterministic site below `tools/scale-smoke/.generated`, runs an existing
//! Boris binary against it, reports the requested page count and elapsed time,
//! then removes that owned directory.

const std = @import("std");
const Io = std.Io;

const generated_root = "tools/scale-smoke/.generated";
const default_page_count: usize = 100;
const satellites_per_section: usize = 24;

const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    failed = 3,
};

const Options = struct {
    page_count: usize = default_page_count,
    boris_path: []const u8 = "./zig-out/bin/boris",
    help: bool = false,
};

const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidPageCount,
};

fn parseOptions(args: []const []const u8) ParseError!Options {
    var options: Options = .{};
    var index: usize = if (args.len == 0) 0 else 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.startsWith(u8, arg, "--pages=")) {
            options.page_count = try parsePageCount(arg["--pages=".len..]);
        } else if (std.mem.eql(u8, arg, "--pages")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.page_count = try parsePageCount(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--boris=")) {
            const value = arg["--boris=".len..];
            if (value.len == 0) return error.MissingValue;
            options.boris_path = value;
        } else if (std.mem.eql(u8, arg, "--boris")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.boris_path = args[index];
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

fn parsePageCount(value: []const u8) ParseError!usize {
    const count = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPageCount;
    if (count == 0) return error.InvalidPageCount;
    return count;
}

fn printUsage() void {
    std.debug.print(
        \\boris-scale-smoke — opt-in synthetic HTML scale smoke
        \\
        \\Usage:
        \\  zig run tools/scale-smoke/main.zig -- [options]
        \\
        \\Options:
        \\  --pages N       Generated page count (default: 100)
        \\  --boris PATH    Built Boris executable (default: ./zig-out/bin/boris)
        \\  -h, --help       Show this help and exit
        \\
        \\The harness owns and removes only tools/scale-smoke/.generated.
        \\
    , .{});
}

fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn writeIndex(io: Io, page_count: usize) !void {
    const body = if (page_count == 1)
        \\---
        \\id: index
        \\title: Scale Smoke Home
        \\status: published
        \\---
        \\# Scale Smoke Home
        \\
        \\{{include includes/common.md}}
        \\
    else
        \\---
        \\id: index
        \\title: Scale Smoke Home
        \\status: published
        \\---
        \\# Scale Smoke Home
        \\
        \\{{include includes/common.md}}
        \\
        \\Start with [[sections/section-0000]].
        \\
    ;
    try writeFile(io, generated_root ++ "/content/index.md", body);
}

fn writeSection(io: Io, section: usize) !void {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/content/sections/section-{d:0>4}.md",
        .{ generated_root, section },
    );
    var body_buffer: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        \\---
        \\id: sections/section-{d:0>4}
        \\title: Scale Section {d}
        \\status: published
        \\---
        \\# Scale Section {d}
        \\
        \\{{include includes/common.md}}
        \\
        \\Return to [[index]].
        \\
    , .{ section, section, section });
    try writeFile(io, path, body);
}

fn writeSatellite(io: Io, page: usize, section: usize) !void {
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/content/articles/article-{d:0>6}.md",
        .{ generated_root, page },
    );
    var body_buffer: [640]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        \\---
        \\id: articles/article-{d:0>6}
        \\title: Scale Article {d}
        \\parent: sections/section-{d:0>4}
        \\status: published
        \\---
        \\# Scale Article {d}
        \\
        \\{{include includes/common.md}}
        \\
        \\This Satellite belongs to [[sections/section-{d:0>4}]] and links to [[index]].
        \\
    , .{ page, page, section, page, section });
    try writeFile(io, path, body);
}

fn generateSite(io: Io, page_count: usize) !void {
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, generated_root) catch {};
    errdefer cwd.deleteTree(io, generated_root) catch {};

    try cwd.createDirPath(io, generated_root ++ "/content/includes");
    try cwd.createDirPath(io, generated_root ++ "/content/sections");
    try cwd.createDirPath(io, generated_root ++ "/content/articles");
    try cwd.createDirPath(io, generated_root ++ "/layouts");

    try writeFile(io, generated_root ++ "/layouts/main.html",
        \\<!doctype html>
        \\<html lang="en">
        \\<head><meta charset="utf-8"><title>{{title}}</title></head>
        \\<body><nav>{{nav}}</nav><main>{{content}}</main></body>
        \\</html>
        \\
    );
    try writeFile(io, generated_root ++ "/content/includes/common.md",
        \\Generated shared fragment.
        \\{{include includes/shared.md}}
        \\
    );
    try writeFile(io, generated_root ++ "/content/includes/shared.md",
        \\Shared link: [[index]].
        \\
    );
    try writeIndex(io, page_count);

    var generated_pages: usize = 1;
    var section: usize = 0;
    while (generated_pages < page_count) : (section += 1) {
        try writeSection(io, section);
        generated_pages += 1;

        var satellites: usize = 0;
        while (generated_pages < page_count and satellites < satellites_per_section) : (satellites += 1) {
            try writeSatellite(io, generated_pages, section);
            generated_pages += 1;
        }
    }
}

fn runSmoke(io: Io, gpa: std.mem.Allocator, options: Options) !void {
    try generateSite(io, options.page_count);

    const start = Io.Clock.awake.now(io);
    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            options.boris_path,
            "--input",
            generated_root ++ "/content",
            "--html-dir",
            generated_root ++ "/dist",
            "--html-layout",
            generated_root ++ "/layouts/main.html",
            "--quiet",
        },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const elapsed_ns = start.untilNow(io, .awake).nanoseconds;

    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});

    switch (result.term) {
        .exited => |code| if (code != 0) return error.BorisFailed,
        else => return error.BorisFailed,
    }
    std.debug.print("scale-smoke: pages={d} elapsed_ms={d}\n", .{
        options.page_count,
        @divTrunc(elapsed_ns, std.time.ns_per_ms),
    });
}

pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();
    const args_z = init.minimal.args.toSlice(cold) catch {
        std.debug.print("scale-smoke: unable to read process arguments\n", .{});
        return @intFromEnum(ExitCode.usage);
    };
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(cold);
    args.ensureTotalCapacity(cold, args_z.len) catch return @intFromEnum(ExitCode.usage);
    for (args_z) |arg| args.appendAssumeCapacity(arg);

    const options = parseOptions(args.items) catch |err| {
        std.debug.print("scale-smoke: {s}\n", .{@errorName(err)});
        printUsage();
        return @intFromEnum(ExitCode.usage);
    };
    if (options.help) {
        printUsage();
        return @intFromEnum(ExitCode.success);
    }

    const cwd = Io.Dir.cwd();
    defer cwd.deleteTree(init.io, generated_root) catch {};
    runSmoke(init.io, init.gpa, options) catch |err| {
        std.debug.print("scale-smoke: failed: {s}\n", .{@errorName(err)});
        return @intFromEnum(ExitCode.failed);
    };
    return @intFromEnum(ExitCode.success);
}

test "parse options has a modest default and accepts a large page count" {
    const defaults = try parseOptions(&.{"scale-smoke"});
    try std.testing.expectEqual(default_page_count, defaults.page_count);

    const large = try parseOptions(&.{ "scale-smoke", "--pages", "10000", "--boris=./boris" });
    try std.testing.expectEqual(@as(usize, 10_000), large.page_count);
    try std.testing.expectEqualStrings("./boris", large.boris_path);
}

test "page count must be positive" {
    try std.testing.expectError(error.InvalidPageCount, parseOptions(&.{ "scale-smoke", "--pages=0" }));
}
