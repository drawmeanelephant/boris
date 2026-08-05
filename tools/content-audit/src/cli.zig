//! CLI parsing for boris-content-audit.
//!
//! Both `--flag=value` and `--flag value` forms are accepted. Usage errors
//! map to exit code 2.

const std = @import("std");
const util = @import("util.zig");

pub const Mode = enum {
    poetry,

    pub fn parse(s: []const u8) ?Mode {
        if (util.eql(s, "poetry")) return .poetry;
        return null;
    }

    pub fn jsonName(self: Mode) []const u8 {
        return switch (self) {
            .poetry => "poetry",
        };
    }
};

pub const Format = enum {
    json,
    markdown,
    html,
    all,

    pub fn parse(s: []const u8) ?Format {
        if (util.eql(s, "json")) return .json;
        if (util.eql(s, "markdown") or util.eql(s, "md")) return .markdown;
        if (util.eql(s, "html")) return .html;
        if (util.eql(s, "all")) return .all;
        return null;
    }

    pub fn includeJson(self: Format) bool {
        return self == .json or self == .all;
    }
    pub fn includeMarkdown(self: Format) bool {
        return self == .markdown or self == .all;
    }
    pub fn includeHtml(self: Format) bool {
        return self == .html or self == .all;
    }
};

pub const FailOn = enum {
    none,
    structural,
    policy,

    pub fn parse(s: []const u8) ?FailOn {
        if (util.eql(s, "none")) return .none;
        if (util.eql(s, "structural")) return .structural;
        if (util.eql(s, "policy")) return .policy;
        return null;
    }
};

pub const Options = struct {
    help: bool = false,
    quiet: bool = false,
    mode: Mode = .poetry,
    root_dir: []const u8 = ".",
    content_root: []const u8 = "content",
    out_dir: ?[]const u8 = null,
    policy_path: ?[]const u8 = null,
    previous_report_path: ?[]const u8 = null,
    collections: []const []const u8 = &.{},
    format: Format = .all,
    fail_on: FailOn = .structural,
    source_revision: ?[]const u8 = null,
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
    UnknownMode,
    OutOfMemory,
};

fn pushCollection(gpa: std.mem.Allocator, options: *Options, value: []const u8) !void {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(gpa, options.collections);
    try list.append(gpa, value);
    options.collections = try list.toOwnedSlice(gpa);
}

pub fn parseOptions(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var options: Options = .{};
    var index: usize = if (args.len == 0) 0 else 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (util.eql(arg, "--help") or util.eql(arg, "-h")) {
            options.help = true;
        } else if (util.eql(arg, "--quiet") or util.eql(arg, "-q")) {
            options.quiet = true;
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            const value = arg["--mode=".len..];
            if (value.len == 0) return error.MissingValue;
            options.mode = Mode.parse(value) orelse return error.UnknownMode;
        } else if (util.eql(arg, "--mode")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.mode = Mode.parse(args[index]) orelse return error.UnknownMode;
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            const value = arg["--root=".len..];
            if (value.len == 0) return error.MissingValue;
            options.root_dir = value;
        } else if (util.eql(arg, "--root")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.root_dir = args[index];
        } else if (std.mem.startsWith(u8, arg, "--content-root=")) {
            const value = arg["--content-root=".len..];
            if (value.len == 0) return error.MissingValue;
            options.content_root = value;
        } else if (util.eql(arg, "--content-root")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.content_root = args[index];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            const value = arg["--out=".len..];
            if (value.len == 0) return error.MissingValue;
            options.out_dir = value;
        } else if (util.eql(arg, "--out")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.out_dir = args[index];
        } else if (std.mem.startsWith(u8, arg, "--policy=")) {
            const value = arg["--policy=".len..];
            if (value.len == 0) return error.MissingValue;
            options.policy_path = value;
        } else if (util.eql(arg, "--policy")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.policy_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--previous-report=")) {
            const value = arg["--previous-report=".len..];
            if (value.len == 0) return error.MissingValue;
            options.previous_report_path = value;
        } else if (util.eql(arg, "--previous-report")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.previous_report_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--collection=")) {
            const value = arg["--collection=".len..];
            if (value.len == 0) return error.MissingValue;
            try pushCollection(gpa, &options, value);
        } else if (util.eql(arg, "--collection")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            try pushCollection(gpa, &options, args[index]);
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            const value = arg["--format=".len..];
            options.format = Format.parse(value) orelse return error.InvalidValue;
        } else if (util.eql(arg, "--format")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.format = Format.parse(args[index]) orelse return error.InvalidValue;
        } else if (std.mem.startsWith(u8, arg, "--fail-on=")) {
            const value = arg["--fail-on=".len..];
            options.fail_on = FailOn.parse(value) orelse return error.InvalidValue;
        } else if (util.eql(arg, "--fail-on")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.fail_on = FailOn.parse(args[index]) orelse return error.InvalidValue;
        } else if (std.mem.startsWith(u8, arg, "--revision=")) {
            const value = arg["--revision=".len..];
            if (value.len == 0) return error.MissingValue;
            options.source_revision = value;
        } else if (util.eql(arg, "--revision")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.source_revision = args[index];
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

pub const help_text =
    \\boris-content-audit — standalone deterministic source-content audit tool.
    \\
    \\Usage:
    \\  boris-content-audit --mode=poetry --root=DIR --content-root=content --out=DIR [options]
    \\
    \\Flags:
    \\  --mode=poetry                 Audit mode (registry; poetry is the initial mode).
    \\  --root=DIR                    Project root (default "."). Never mutated.
    \\  --content-root=RELATIVE_DIR   Content root relative to --root (default "content").
    \\  --out=DIR                     Output directory (required). Tool-owned, atomic,
    \\                                never inside the content root.
    \\  --policy=FILE                 Optional versioned JSON policy defining editorial
    \\                                expectations (eligible/poetry collections, placeholder
    \\                                signatures, density bands, exact mappings).
    \\  --previous-report=FILE        Optional earlier report.json for delta comparison.
    \\  --collection=NAME             Repeatable filter restricting coverage/records.
    \\  --format=json|markdown|html|all  Report formats to emit (default all).
    \\  --quiet                       Suppress the summary line.
    \\  --fail-on=none|structural|policy  Failure class that makes exit code 1
    \\                                (default structural).
    \\  --revision=STRING             Optional explicit source revision (never host-derived).
    \\  --help                        Show this help.
    \\
    \\Exit codes:
    \\  0  audit completed, no selected failure class triggered
    \\  1  findings selected by --fail-on were present
    \\  2  usage error
    \\  3  I/O or output-ownership error
    \\  4  malformed source, policy, or previous-report contract
    \\
    \\Examples:
    \\  zig build --build-file tools/content-audit/build.zig run -- \
    \\    --mode=poetry --root=/path/to/project --content-root=content \
    \\    --policy=/path/to/policy.json --out=/tmp/poetry-audit
    \\
;
