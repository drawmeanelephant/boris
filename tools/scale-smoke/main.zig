//! Opt-in synthetic scale smoke for Boris.
//!
//! This is deliberately outside build.zig and mandatory CI. It creates one
//! deterministic site below `tools/scale-smoke/.generated`, runs an existing
//! Boris binary against it, reports the requested page count and elapsed time,
//! then removes that owned directory.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Sha256 = std.crypto.hash.sha2.Sha256;

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
    optimize_mode: []const u8 = "unknown",
    runs: usize = 3,
    report_path: []const u8 = "BENCHMARK-REPORT.md",
    jobs: [8]usize = .{ 1, 8, 0, 0, 0, 0, 0, 0 },
    job_count: usize = 2,
    jobs_explicit: bool = false,
    help: bool = false,
};

const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidPageCount,
    InvalidRuns,
    InvalidJobs,
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
        } else if (std.mem.startsWith(u8, arg, "--optimize=")) {
            options.optimize_mode = arg["--optimize=".len..];
            if (options.optimize_mode.len == 0) return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--optimize")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.optimize_mode = args[index];
        } else if (std.mem.startsWith(u8, arg, "--runs=")) {
            options.runs = try parsePositive(arg["--runs=".len..], error.InvalidRuns);
        } else if (std.mem.eql(u8, arg, "--runs")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.runs = try parsePositive(args[index], error.InvalidRuns);
        } else if (std.mem.startsWith(u8, arg, "--report=")) {
            options.report_path = arg["--report=".len..];
            if (options.report_path.len == 0) return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--report")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.report_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            try appendJob(&options, arg["--jobs=".len..]);
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            try appendJob(&options, args[index]);
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

fn parsePositive(value: []const u8, comptime err: ParseError) ParseError!usize {
    const count = std.fmt.parseInt(usize, value, 10) catch return err;
    if (count == 0) return err;
    return count;
}

fn appendJob(options: *Options, value: []const u8) ParseError!void {
    const jobs = try parsePositive(value, error.InvalidJobs);
    if (!options.jobs_explicit) {
        options.job_count = 0;
        options.jobs_explicit = true;
    }
    if (options.job_count >= options.jobs.len) return error.InvalidJobs;
    options.jobs[options.job_count] = jobs;
    options.job_count += 1;
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
        \\  --optimize MODE Optimization label for the report (default: unknown)
        \\  --runs N        Cold builds per worker setting (default: 3)
        \\  --jobs N        Worker setting; repeat to compare (default: 1, 8)
        \\  --report PATH   Markdown report path (default: BENCHMARK-REPORT.md)
        \\  -h, --help       Show this help and exit
        \\
        \\The harness owns and removes only tools/scale-smoke/.generated.
        \\
    , .{});
}

const FileStats = struct {
    bytes: u64 = 0,
    digest: [Sha256.digest_length]u8 = undefined,
};

fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectFiles(io: Io, gpa: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var root = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer root.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |file| gpa.free(file);
        files.deinit(gpa);
    }
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) try files.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, pathLess);
    return try files.toOwnedSlice(gpa);
}

fn freeFiles(gpa: std.mem.Allocator, files: [][]const u8) void {
    for (files) |file| gpa.free(file);
    gpa.free(files);
}

fn readRelative(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

fn treeStats(io: Io, gpa: std.mem.Allocator, path: []const u8) !FileStats {
    var root = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer root.close(io);
    const files = try collectFiles(io, gpa, path);
    defer freeFiles(gpa, files);
    var hasher = Sha256.init(.{});
    var stats = FileStats{};
    for (files) |rel| {
        const data = try readRelative(io, gpa, root, rel);
        defer gpa.free(data);
        stats.bytes += data.len;
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, rel.len, .little);
        hasher.update(&len_buf);
        hasher.update(rel);
        std.mem.writeInt(u64, &len_buf, data.len, .little);
        hasher.update(&len_buf);
        hasher.update(data);
    }
    hasher.final(&stats.digest);
    return stats;
}

fn hexDigest(digest: [Sha256.digest_length]u8) [Sha256.digest_length * 2]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

fn appendFmt(list: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(text);
    try list.appendSlice(gpa, text);
}

fn commandText(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return try gpa.dupe(u8, "unavailable");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.stdout.len == 0) return try gpa.dupe(u8, "unavailable");
    return try gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn cpuModel(gpa: std.mem.Allocator, io: Io) ![]u8 {
    if (builtin.os.tag == .macos) {
        const model = try commandText(gpa, io, &.{ "sysctl", "-n", "machdep.cpu.brand_string" });
        if (!std.mem.eql(u8, model, "unavailable")) return model;
        gpa.free(model);
        const hardware = try commandText(gpa, io, &.{ "sysctl", "-n", "hw.model" });
        if (!std.mem.eql(u8, hardware, "unavailable")) return hardware;
        gpa.free(hardware);
    }
    if (builtin.os.tag == .linux) {
        const data = Io.Dir.cwd().readFile(io, "/proc/cpuinfo", gpa, .unlimited) catch return try gpa.dupe(u8, "unavailable");
        defer gpa.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "model name")) {
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| return try gpa.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"));
            }
        }
    }
    return try gpa.dupe(u8, "unavailable");
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
    const body = try std.fmt.bufPrint(&body_buffer,
        \\---
        \\id: sections/section-{d:0>4}
        \\title: Scale Section {d}
        \\status: published
        \\---
        \\# Scale Section {d}
        \\
        \\{{{{include includes/common.md}}}}
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
    const body = try std.fmt.bufPrint(&body_buffer,
        \\---
        \\id: articles/article-{d:0>6}
        \\title: Scale Article {d}
        \\parent: sections/section-{d:0>4}
        \\status: published
        \\---
        \\# Scale Article {d}
        \\
        \\{{{{include includes/common.md}}}}
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

const Sample = struct {
    jobs: usize,
    run: usize,
    cleanup_ns: u64,
    compile_ns: u64,
    output: FileStats,
    peak_rss: []const u8,
};

fn elapsedNs(io: Io, start: Io.Timestamp, clock: Io.Clock) u64 {
    return @intCast(start.untilNow(io, clock).nanoseconds);
}

fn parsePeakRss(gpa: std.mem.Allocator, stderr: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Maximum resident set size")) |colon| {
            const value_start = std.mem.indexOfScalarPos(u8, line, colon, ':') orelse continue;
            const value = std.mem.trim(u8, line[value_start + 1 ..], " \t");
            if (value.len == 0) continue;
            return try gpa.dupe(u8, value);
        }
        if (std.mem.indexOf(u8, line, "maximum resident set size")) |start| {
            const value = std.mem.trim(u8, line[start + "maximum resident set size".len ..], " \t");
            if (value.len > 0) return try gpa.dupe(u8, value);
        }
    }
    return try gpa.dupe(u8, "unavailable");
}

fn runCompile(io: Io, gpa: std.mem.Allocator, options: Options, jobs: usize, run: usize) !Sample {
    const output_path = generated_root ++ "/dist";
    const cleanup_timer = Io.Clock.awake.now(io);
    Io.Dir.cwd().deleteTree(io, output_path) catch {};
    const cleanup_ns = elapsedNs(io, cleanup_timer, .awake);

    var argv: [12][]const u8 = undefined;
    var argv_len: usize = 0;
    if (builtin.os.tag == .linux) {
        argv[argv_len] = "/usr/bin/time";
        argv_len += 1;
        argv[argv_len] = "-v";
        argv_len += 1;
    }
    argv[argv_len] = options.boris_path;
    argv_len += 1;
    argv[argv_len] = "--input";
    argv_len += 1;
    argv[argv_len] = generated_root ++ "/content";
    argv_len += 1;
    argv[argv_len] = "--html-dir";
    argv_len += 1;
    argv[argv_len] = output_path;
    argv_len += 1;
    argv[argv_len] = "--html-layout";
    argv_len += 1;
    argv[argv_len] = generated_root ++ "/layouts/main.html";
    argv_len += 1;
    argv[argv_len] = "--jobs";
    argv_len += 1;
    var jobs_buf: [20]u8 = undefined;
    argv[argv_len] = try std.fmt.bufPrint(&jobs_buf, "{d}", .{jobs});
    argv_len += 1;
    argv[argv_len] = "--quiet";
    argv_len += 1;

    const start = Io.Clock.awake.now(io);
    const result = std.process.run(gpa, io, .{ .argv = argv[0..argv_len] }) catch |err| return err;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const compile_ns = elapsedNs(io, start, .awake);
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    switch (result.term) {
        .exited => |code| if (code != 0) return error.BorisFailed,
        else => return error.BorisFailed,
    }
    return .{
        .jobs = jobs,
        .run = run,
        .cleanup_ns = cleanup_ns,
        .compile_ns = compile_ns,
        .output = try treeStats(io, gpa, output_path),
        .peak_rss = try parsePeakRss(gpa, result.stderr),
    };
}

fn appendReport(io: Io, gpa: std.mem.Allocator, options: Options, samples: []const Sample, input: FileStats, os: []const u8, cpu: []const u8, zig_version: []const u8, cores: []const u8) !void {
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);
    try report.appendSlice(gpa, "# Boris benchmark report\n\n");
    try report.appendSlice(gpa, "This is an opt-in synthetic cold-build benchmark, not a compiler behavior or CI gate. Each sample deletes the prior output tree first; `cleanup_ms` is measured separately, and `compile_ms` begins after that deletion completes.\n\n");
    try report.appendSlice(gpa, "## Environment\n\n");
    try appendFmt(&report, gpa, "| Field | Value |\n|---|---|\n| OS | {s} |\n| CPU model | {s} |\n| CPU cores | {s} |\n| Zig version | {s} |\n| Optimization mode | {s} |\n| Input bytes | {d} |\n| Requested runs per worker setting | {d} |\n\n", .{ os, cpu, cores, zig_version, options.optimize_mode, input.bytes, options.runs });
    try report.appendSlice(gpa, "The output digest is SHA-256 over sorted relative output paths, each path length, path bytes, file length, and file bytes. Equal digests and byte counts across runs are the determinism check. Peak RSS is reported in the host `/usr/bin/time` unit when that wrapper is available.\n\n");
    try report.appendSlice(gpa, "## Samples\n\n| Workers | Run | Cleanup (ms) | Compile (ms) | Output bytes | Output SHA-256 | Peak RSS |\n|---:|---:|---:|---:|---:|---|---|\n");
    for (samples) |sample| {
        const digest = hexDigest(sample.output.digest);
        try appendFmt(&report, gpa, "| {d} | {d} | {d}.{d:0>3} | {d}.{d:0>3} | {d} | `{s}` | {s} |\n", .{
            sample.jobs,                                      sample.run,
            @divTrunc(sample.cleanup_ns, std.time.ns_per_ms), @mod(@divTrunc(sample.cleanup_ns, std.time.ns_per_us), 1000),
            @divTrunc(sample.compile_ns, std.time.ns_per_ms), @mod(@divTrunc(sample.compile_ns, std.time.ns_per_us), 1000),
            sample.output.bytes,                              digest,
            sample.peak_rss,
        });
    }
    try report.appendSlice(gpa, "\n## Arithmetic and interpretation\n\n");
    var jobs_seen: [8]usize = undefined;
    var jobs_seen_count: usize = 0;
    for (samples) |sample| {
        var known = false;
        for (jobs_seen[0..jobs_seen_count]) |job| {
            if (job == sample.jobs) known = true;
        }
        if (known) continue;
        jobs_seen[jobs_seen_count] = sample.jobs;
        jobs_seen_count += 1;
        var total_cleanup: u64 = 0;
        var total_compile: u64 = 0;
        var count: u64 = 0;
        var first_digest: ?[Sha256.digest_length]u8 = null;
        var deterministic = true;
        for (samples) |candidate| if (candidate.jobs == sample.jobs) {
            total_cleanup += candidate.cleanup_ns;
            total_compile += candidate.compile_ns;
            count += 1;
            if (first_digest == null) first_digest = candidate.output.digest else if (!std.mem.eql(u8, &first_digest.?, &candidate.output.digest)) deterministic = false;
        };
        const digest = hexDigest(first_digest.?);
        try appendFmt(&report, gpa, "- **-j{d}:** arithmetic mean cleanup `{d}.{d:0>3} ms`, arithmetic mean compile `{d}.{d:0>3} ms` over {d} samples; digest `{s}`; deterministic: **{s}**.\n", .{
            sample.jobs,
            @divTrunc(total_cleanup / count, std.time.ns_per_ms),
            @mod(@divTrunc(total_cleanup / count, std.time.ns_per_us), 1000),
            @divTrunc(total_compile / count, std.time.ns_per_ms),
            @mod(@divTrunc(total_compile / count, std.time.ns_per_us), 1000),
            count,
            digest,
            if (deterministic) "yes" else "no",
        });
    }
    try report.appendSlice(gpa, "\nWorker comparisons are valid only within this report. Comparisons across machines are **non-comparable unless OS, CPU model, core count, Zig version, optimization mode, input bytes, and worker settings match**; elapsed time and RSS are environment observations, not portable performance claims.\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = options.report_path, .data = report.items });
}

fn runSmoke(io: Io, gpa: std.mem.Allocator, options: Options) !void {
    try generateSite(io, options.page_count);
    const input = try treeStats(io, gpa, generated_root ++ "/content");
    const layout = try treeStats(io, gpa, generated_root ++ "/layouts");
    var input_total = input;
    input_total.bytes += layout.bytes;
    const os = @tagName(builtin.os.tag);
    const cpu = try cpuModel(gpa, io);
    defer gpa.free(cpu);
    const zig_version = try commandText(gpa, io, &.{ "zig", "version" });
    defer gpa.free(zig_version);
    var core_buf: [32]u8 = undefined;
    const cores = std.Thread.getCpuCount() catch 0;
    const core_text = try std.fmt.bufPrint(&core_buf, "{d}", .{cores});
    var samples: std.ArrayList(Sample) = .empty;
    defer {
        for (samples.items) |sample| gpa.free(sample.peak_rss);
        samples.deinit(gpa);
    }
    for (options.jobs[0..options.job_count]) |jobs| {
        var run: usize = 1;
        while (run <= options.runs) : (run += 1) {
            const sample = try runCompile(io, gpa, options, jobs, run);
            try samples.append(gpa, sample);
            std.debug.print("scale-smoke: pages={d} jobs={d} run={d} cleanup_ms={d} compile_ms={d} output_bytes={d}\n", .{
                options.page_count,                               jobs,                                             run,
                @divTrunc(sample.cleanup_ns, std.time.ns_per_ms), @divTrunc(sample.compile_ns, std.time.ns_per_ms), sample.output.bytes,
            });
        }
    }
    try appendReport(io, gpa, options, samples.items, input_total, os, cpu, zig_version, core_text);
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

test "parse options accepts repeated cold-build settings and report metadata" {
    const options = try parseOptions(&.{
        "scale-smoke", "--runs", "4", "--jobs=1", "--jobs", "8", "--optimize", "ReleaseFast", "--report", "out.md",
    });
    try std.testing.expectEqual(@as(usize, 4), options.runs);
    try std.testing.expectEqual(@as(usize, 2), options.job_count);
    try std.testing.expectEqual(@as(usize, 1), options.jobs[0]);
    try std.testing.expectEqual(@as(usize, 8), options.jobs[1]);
    try std.testing.expectEqualStrings("ReleaseFast", options.optimize_mode);
    try std.testing.expectEqualStrings("out.md", options.report_path);
}

test "page count must be positive" {
    try std.testing.expectError(error.InvalidPageCount, parseOptions(&.{ "scale-smoke", "--pages=0" }));
}

test "writeSection and writeSatellite generate correct double-braced include strings" {
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, generated_root ++ "/content/sections") catch {};
    cwd.createDirPath(io, generated_root ++ "/content/articles") catch {};
    defer cwd.deleteTree(io, generated_root) catch {};

    try writeSection(io, 0);
    try writeSatellite(io, 1, 0);

    var section_file = try cwd.openFile(io, generated_root ++ "/content/sections/section-0000.md", .{});
    defer section_file.close(io);
    var section_reader = section_file.reader(io, &.{});
    const section_content = try section_reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(section_content);

    const sec_double = std.mem.indexOf(u8, section_content, "{{include");
    try std.testing.expect(sec_double != null);
    const sec_single = std.mem.indexOf(u8, section_content, "{include");
    try std.testing.expectEqual(sec_double.? + 1, sec_single.?);

    var satellite_file = try cwd.openFile(io, generated_root ++ "/content/articles/article-000001.md", .{});
    defer satellite_file.close(io);
    var satellite_reader = satellite_file.reader(io, &.{});
    const satellite_content = try satellite_reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(satellite_content);

    const sat_double = std.mem.indexOf(u8, satellite_content, "{{include");
    try std.testing.expect(sat_double != null);
    const sat_single = std.mem.indexOf(u8, satellite_content, "{include");
    try std.testing.expectEqual(sat_double.? + 1, sat_single.?);
}
