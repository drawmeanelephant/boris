const std = @import("std");
const Io = std.Io;
const model = @import("model.zig");
const scanner = @import("scanner.zig");
const report = @import("report.zig");

/// Tool id printed by `--version`/`-V`. Kept in lockstep with the product
/// release line (`pipeline.boris_version`); this tool does not import `src/`.
pub const tool_id = "boris-docs-maintenance/0.8.1";

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const raw_args = init.minimal.args.toSlice(arena) catch {
        std.debug.print("Error: Failed to read CLI arguments.\n", .{});
        return 1;
    };

    if (raw_args.len < 2) {
        printUsage();
        return 2;
    }

    const subcommand = raw_args[1];
    if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "help")) {
        printUsage();
        return 0;
    }
    if (std.mem.eql(u8, subcommand, "-V") or std.mem.eql(u8, subcommand, "--version")) {
        var stdout_buffer: [128]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        stdout_writer.interface.writeAll(tool_id ++ "\n") catch {};
        stdout_writer.interface.flush() catch {};
        return 0;
    }

    if (!std.mem.eql(u8, subcommand, "scan")) {
        std.debug.print("Error: Unknown command '{s}'. Expected 'scan'.\n\n", .{subcommand});
        printUsage();
        return 2;
    }

    // Default arguments
    var repo_root: []const u8 = ".";
    var source_root: []const u8 = "src";
    var dossier_root: []const u8 = "docs/boris/src";
    var json_out: []const u8 = "zig-out/docs-maintenance/inventory.json";
    var markdown_out: []const u8 = "zig-out/docs-maintenance/summary.md";

    var i: usize = 2;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("Error: --repo requires a path value.\n", .{});
                return 2;
            }
            repo_root = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--source-root")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("Error: --source-root requires a path value.\n", .{});
                return 2;
            }
            source_root = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--dossier-root")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("Error: --dossier-root requires a path value.\n", .{});
                return 2;
            }
            dossier_root = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("Error: --json requires a path value.\n", .{});
                return 2;
            }
            json_out = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--markdown")) {
            i += 1;
            if (i >= raw_args.len) {
                std.debug.print("Error: --markdown requires a path value.\n", .{});
                return 2;
            }
            markdown_out = raw_args[i];
        } else {
            std.debug.print("Error: Unknown argument '{s}'.\n", .{arg});
            return 2;
        }
    }

    // Execute scan
    var sc = scanner.Scanner.init(gpa, .{
        .repo_root = repo_root,
        .source_root = source_root,
        .dossier_root = dossier_root,
    });
    defer sc.deinit();

    const inv_report = sc.scan(io) catch |err| {
        std.debug.print("docs-maintenance operational failure: scan failed with error '{s}'.\n", .{@errorName(err)});
        return 1;
    };

    // Sibling temporary replacement write pattern
    writeReportWithTmp(io, arena, json_out, inv_report, writeJsonWrapper) catch |err| {
        std.debug.print("docs-maintenance operational failure: failed to write JSON report '{s}': {s}.\n", .{ json_out, @errorName(err) });
        return 1;
    };

    writeReportWithTmp(io, arena, markdown_out, inv_report, writeMarkdownWrapper) catch |err| {
        std.debug.print("docs-maintenance operational failure: failed to write Markdown summary '{s}': {s}.\n", .{ markdown_out, @errorName(err) });
        return 1;
    };

    std.debug.print("docs-maintenance: scan complete. Inventory JSON: {s}, Markdown summary: {s}\n", .{ json_out, markdown_out });
    return 0;
}

fn writeJsonWrapper(writer: anytype, inv_report: model.InventoryReport) !void {
    try report.writeJsonReport(writer, inv_report);
}

fn writeMarkdownWrapper(writer: anytype, inv_report: model.InventoryReport) !void {
    try report.writeMarkdownSummary(writer, inv_report);
}

fn writeReportWithTmp(
    io: Io,
    allocator: std.mem.Allocator,
    target_path: []const u8,
    inv_report: model.InventoryReport,
    write_fn: fn (anytype, model.InventoryReport) anyerror!void,
) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target_path});
    defer allocator.free(tmp_path);

    const cwd = Io.Dir.cwd();

    // Ensure parent directory exists
    if (std.fs.path.dirname(target_path)) |dir_path| {
        if (dir_path.len > 0) {
            cwd.createDirPath(io, dir_path) catch {};
        }
    }

    var tmp_file = try cwd.createFile(io, tmp_path, .{});
    var write_buf: [4096]u8 = undefined;
    var file_writer = tmp_file.writer(io, &write_buf);

    write_fn(&file_writer.interface, inv_report) catch |err| {
        tmp_file.close(io);
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };

    try file_writer.flush();
    tmp_file.close(io);

    cwd.rename(tmp_path, cwd, target_path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

fn printUsage() void {
    std.debug.print(
        \\boris-docs-maintenance — Standalone Boris Documentation Maintenance Tool
        \\
        \\USAGE:
        \\  docs-maintenance scan [OPTIONS]
        \\
        \\OPTIONS:
        \\  --repo <path>          Repository root path (default: .)
        \\  --source-root <path>   Source root relative to repo (default: src)
        \\  --dossier-root <path>  Optional dossier claim root (default: docs/boris/src; missing dir skipped)
        \\  --json <path>          Output JSON inventory path (default: zig-out/docs-maintenance/inventory.json)
        \\  --markdown <path>      Output Markdown summary path (default: zig-out/docs-maintenance/summary.md)
        \\  -h, --help             Display this help message
        \\  -V, --version          Print the tool id and exit
        \\
        \\EXIT STATUS:
        \\  0  Successful scan; trustworthy reports published.
        \\  1  Operational failure (scan or I/O failure).
        \\  2  Invalid CLI usage.
        \\
    , .{});
}
