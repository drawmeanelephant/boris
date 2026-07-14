//! Typed CLI parser for the Boris product surface (milestone 3).
//!
//! Parses argv into a single canonical `Options` value. Does not open paths,
//! read config files, or consult environment variables.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const RunResult = diagnostic.RunResult;

/// Build mode selected by flags.
pub const Mode = enum {
    /// Emit content-compiler IR under `--out` (default `.boris`).
    ir,
    /// RAG-only export under `--rag-dir` (default `rag`).
    rag,
    /// HTML site render under `--html-dir` (default `dist`).
    html,
};

/// Canonical parsed options. Strings are views into argv (or static defaults).
pub const Options = struct {
    /// When true, print help and exit successfully (no pipeline).
    help: bool = false,
    quiet: bool = false,
    mode: Mode = .ir,
    /// Content root (default `content`).
    input_dir: []const u8 = "content",
    /// IR output directory. Set for IR mode only (default `.boris`).
    out_dir: ?[]const u8 = null,
    /// RAG corpus directory. Set for RAG mode only (default `rag`).
    rag_dir: ?[]const u8 = null,
    /// HTML output directory. Set for HTML mode only (default `dist`).
    html_dir: ?[]const u8 = null,
    /// Explicit incremental HTML build mode. Valid only with --html/--html-dir.
    incremental: bool = false,
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    EmptyValue,
    UnexpectedPositional,
    ConflictingFlags,
    DuplicateFlag,
};

const default_input_dir = "content";
const default_out_dir = ".boris";
const default_rag_dir = "rag";
const default_html_dir = "dist";

/// Parse argv into `Options`. Does not print, exit, or touch the filesystem.
///
/// `args[0]` is the program name when present (skipped).
/// `--help` / `-h` short-circuit: remaining args are not validated.
pub fn parseOptions(args: []const []const u8) ParseError!Options {
    var quiet = false;
    var input_dir: []const u8 = default_input_dir;
    var out_dir: []const u8 = default_out_dir;
    var rag_dir: []const u8 = default_rag_dir;
    var html_dir: []const u8 = default_html_dir;

    var saw_quiet = false;
    var saw_input = false;
    var saw_out = false;
    var saw_rag = false;
    var saw_no_rag = false;
    var saw_rag_dir = false;
    var saw_html = false;
    var saw_html_dir = false;
    var saw_incremental = false;

    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];

        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            // Help short-circuits: do not validate remaining args.
            return .{
                .help = true,
                .quiet = quiet,
                .mode = .ir,
                .input_dir = input_dir,
                .out_dir = out_dir,
                .rag_dir = null,
                .html_dir = null,
            };
        }

        if (std.mem.eql(u8, a, "--quiet")) {
            if (saw_quiet) return error.DuplicateFlag;
            saw_quiet = true;
            quiet = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--rag")) {
            if (saw_rag) return error.DuplicateFlag;
            saw_rag = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--no-rag")) {
            if (saw_no_rag) return error.DuplicateFlag;
            saw_no_rag = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--html")) {
            if (saw_html) return error.DuplicateFlag;
            saw_html = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--incremental")) {
            if (saw_incremental) return error.DuplicateFlag;
            saw_incremental = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--input") or std.mem.startsWith(u8, a, "--input=")) {
            if (saw_input) return error.DuplicateFlag;
            saw_input = true;
            input_dir = try takeValue(args, &i, a, "--input");
            continue;
        }

        if (std.mem.eql(u8, a, "--out") or std.mem.startsWith(u8, a, "--out=")) {
            if (saw_out) return error.DuplicateFlag;
            saw_out = true;
            out_dir = try takeValue(args, &i, a, "--out");
            continue;
        }

        if (std.mem.eql(u8, a, "--rag-dir") or std.mem.startsWith(u8, a, "--rag-dir=")) {
            if (saw_rag_dir) return error.DuplicateFlag;
            saw_rag_dir = true;
            rag_dir = try takeValue(args, &i, a, "--rag-dir");
            continue;
        }

        if (std.mem.eql(u8, a, "--html-dir") or std.mem.startsWith(u8, a, "--html-dir=")) {
            if (saw_html_dir) return error.DuplicateFlag;
            saw_html_dir = true;
            html_dir = try takeValue(args, &i, a, "--html-dir");
            continue;
        }

        if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        }
        return error.UnexpectedPositional;
    }

    // --- conflict matrix ---------------------------------------------------
    if (saw_rag and saw_no_rag) return error.ConflictingFlags;
    if (saw_no_rag and saw_rag_dir) return error.ConflictingFlags;
    // Explicit --out must never be combined with RAG-only selection.
    if (saw_out and (saw_rag or saw_rag_dir)) return error.ConflictingFlags;
    // HTML/SSG mode owns its output destination; refuse IR/RAG output flags.
    if ((saw_html or saw_html_dir) and (saw_rag or saw_rag_dir or saw_out)) {
        return error.ConflictingFlags;
    }
    // Incremental option is valid only when combined with HTML mode.
    if (saw_incremental and !(saw_html or saw_html_dir)) {
        return error.ConflictingFlags;
    }

    // Mode selection:
    // 1. Default → IR
    // 2. --no-rag → IR
    // 3. --rag / --rag-dir → RAG-only
    // 4. --html / --html-dir → HTML site
    const mode: Mode = if (saw_html or saw_html_dir)
        .html
    else if (saw_rag or saw_rag_dir)
        .rag
    else
        .ir;

    return switch (mode) {
        .ir => .{
            .help = false,
            .quiet = quiet,
            .mode = .ir,
            .input_dir = input_dir,
            .out_dir = out_dir,
            .rag_dir = null,
            .html_dir = null,
        },
        .rag => .{
            .help = false,
            .quiet = quiet,
            .mode = .rag,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = rag_dir,
            .html_dir = null,
        },
        .html => .{
            .help = false,
            .quiet = quiet,
            .mode = .html,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = null,
            .html_dir = html_dir,
            .incremental = saw_incremental,
        },
    };
}

/// Read a value for `--name` or `--name=value`. Advances `i` when the value is
/// the next argv token. Empty values are usage errors.
fn takeValue(
    args: []const []const u8,
    i: *usize,
    arg: []const u8,
    comptime name: []const u8,
) ParseError![]const u8 {
    const eq_prefix = name ++ "=";
    if (std.mem.startsWith(u8, arg, eq_prefix)) {
        const v = arg[eq_prefix.len..];
        if (v.len == 0) return error.EmptyValue;
        return v;
    }
    // Space-separated: --name <value>
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    const v = args[i.*];
    if (v.len == 0) return error.EmptyValue;
    return v;
}

pub fn printUsage() void {
    std.debug.print(
        \\Boris — Zig content compiler (IR + optional RAG + opt-in HTML)
        \\
        \\Usage: boris [options]
        \\
        \\Modes:
        \\  (default)           IR mode → write JSON under --out (default .boris)
        \\  --no-rag            Explicit IR mode
        \\  --rag               RAG-only mode → corpus under --rag-dir (default rag)
        \\  --rag-dir <DIR>     RAG-only mode with output directory DIR
        \\  --html              HTML site mode → pages under --html-dir (default dist)
        \\  --html-dir <DIR>    HTML site mode with output directory DIR
        \\
        \\Options:
        \\  --input <DIR>       Content root (default: content)
        \\  --out <DIR>         IR output directory (default: .boris; IR mode only)
        \\  --rag-dir <DIR>     RAG corpus directory (implies RAG-only; default: rag)
        \\  --html-dir <DIR>    HTML output directory (implies HTML; default: dist)
        \\  --incremental       Opt-in to fast, content-addressed incremental HTML rendering (requires HTML mode)
        \\  --quiet             Suppress progress + diagnostic stderr (exit codes/artifacts unchanged)
        \\  -h, --help          Show this help and exit 0
        \\
        \\IR artifacts (success):
        \\  <out>/manifest.json  <out>/graph.json  <out>/build-report.json
        \\
        \\RAG artifacts (success; same graph validation as IR):
        \\  INDEX.md  UPLOAD-GUIDE.md  catalog.jsonl  catalog_meta.json
        \\  system/**  content/pages/**  graph/entity-catalog.md  graph/relations.md
        \\
        \\HTML artifacts (success; Apex + layout splice; layout: layouts/main.html):
        \\  <html-dir>/**/*.html
        \\
        \\Conflicts (exit 2):
        \\  --rag with --no-rag
        \\  --no-rag with --rag-dir
        \\  explicit --out with --rag or --rag-dir
        \\  --html / --html-dir with --rag, --rag-dir, or explicit --out
        \\
        \\Exit codes: 0 success, 1 content validation, 2 usage, 3 I/O/system
        \\
        \\Note: HTML is opt-in via --html / --html-dir; default remains IR.
        \\
    , .{});
}

/// Print a usage diagnostic. Uses `std.debug.print` (not `std.log.err`) so
/// unit tests that exercise the usage path are not failed by the test logger.
pub fn printParseError(err: ParseError, bad_arg: ?[]const u8) void {
    switch (err) {
        error.UnknownFlag => {
            if (bad_arg) |a| {
                std.debug.print("error: unknown option: {s} (try --help)\n", .{a});
            } else {
                std.debug.print("error: unknown option (try --help)\n", .{});
            }
        },
        error.MissingValue => {
            if (bad_arg) |a| {
                std.debug.print("error: missing value for {s}\n", .{a});
            } else {
                std.debug.print("error: missing option value\n", .{});
            }
        },
        error.EmptyValue => {
            if (bad_arg) |a| {
                std.debug.print("error: empty value for {s}\n", .{a});
            } else {
                std.debug.print("error: empty option value\n", .{});
            }
        },
        error.UnexpectedPositional => {
            if (bad_arg) |a| {
                std.debug.print("error: unexpected argument: {s} (try --help)\n", .{a});
            } else {
                std.debug.print("error: unexpected positional argument (try --help)\n", .{});
            }
        },
        error.ConflictingFlags => {
            std.debug.print("error: conflicting options (try --help)\n", .{});
        },
        error.DuplicateFlag => {
            if (bad_arg) |a| {
                std.debug.print("error: duplicate option: {s}\n", .{a});
            } else {
                std.debug.print("error: duplicate option\n", .{});
            }
        },
    }
}

/// Find a likely "bad" argv token for error messages (best-effort).
pub fn findBadArg(args: []const []const u8) ?[]const u8 {
    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) continue;
        if (std.mem.eql(u8, a, "--quiet") or
            std.mem.eql(u8, a, "--rag") or
            std.mem.eql(u8, a, "--no-rag") or
            std.mem.eql(u8, a, "--html") or
            std.mem.eql(u8, a, "--incremental"))
        {
            continue;
        }
        if (std.mem.eql(u8, a, "--input") or
            std.mem.eql(u8, a, "--out") or
            std.mem.eql(u8, a, "--rag-dir") or
            std.mem.eql(u8, a, "--html-dir"))
        {
            // Value may be missing or empty — report the flag name.
            return a;
        }
        if (std.mem.startsWith(u8, a, "--input=") or
            std.mem.startsWith(u8, a, "--out=") or
            std.mem.startsWith(u8, a, "--rag-dir=") or
            std.mem.startsWith(u8, a, "--html-dir="))
        {
            return a;
        }
        return a;
    }
    return null;
}

/// Dispatch parsed options through a small injectable runner.
///
/// - Help: calls `runner.printHelp()` and returns success; never calls `run`.
/// - Build modes: calls `runner.run(opts)` and returns its exit code.
///
/// `runner` must provide `printHelp` and `run` methods.
pub fn execute(opts: Options, runner: anytype) ExitCode {
    if (opts.help) {
        runner.printHelp();
        return .success;
    }
    return runner.run(opts);
}

/// Parse argv and execute. Maps all parse failures to exit code 2.
///
/// On parse failure, calls `runner.reportUsage(err, bad_arg)` when that method
/// exists; otherwise falls back to `printParseError` + `printUsage`.
pub fn runArgs(args: []const []const u8, runner: anytype) u8 {
    const opts = parseOptions(args) catch |err| {
        const bad = findBadArg(args);
        const Runner = @TypeOf(runner.*);
        if (@hasDecl(Runner, "reportUsage")) {
            runner.reportUsage(err, bad);
        } else {
            printParseError(err, bad);
            printUsage();
        }
        return ExitCode.usage.int();
    };
    return execute(opts, runner).int();
}

// --- tests -----------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "parse: default is IR mode" {
    const o = try parseOptions(&.{"boris"});
    try expect(!o.help);
    try expect(!o.quiet);
    try expectEqual(Mode.ir, o.mode);
    try expectEqualStrings(default_input_dir, o.input_dir);
    try expectEqualStrings(default_out_dir, o.out_dir.?);
    try expect(o.rag_dir == null);
    try expect(o.html_dir == null);
}

test "parse: valid modes table" {
    const Case = struct {
        args: []const []const u8,
        mode: Mode,
        input: []const u8,
        out: ?[]const u8,
        rag: ?[]const u8,
        html: ?[]const u8,
        quiet: bool,
    };

    const cases = [_]Case{
        .{
            .args = &.{ "boris", "--no-rag" },
            .mode = .ir,
            .input = "content",
            .out = ".boris",
            .rag = null,
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag" },
            .mode = .rag,
            .input = "content",
            .out = null,
            .rag = "rag",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag-dir", "uploads/rag" },
            .mode = .rag,
            .input = "content",
            .out = null,
            .rag = "uploads/rag",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag-dir=x" },
            .mode = .rag,
            .input = "content",
            .out = null,
            .rag = "x",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag", "--rag-dir", "custom" },
            .mode = .rag,
            .input = "content",
            .out = null,
            .rag = "custom",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--input", "docs", "--out", "build/ir", "--quiet" },
            .mode = .ir,
            .input = "docs",
            .out = "build/ir",
            .rag = null,
            .html = null,
            .quiet = true,
        },
        .{
            .args = &.{ "boris", "--input=site", "--no-rag", "--out=.boris" },
            .mode = .ir,
            .input = "site",
            .out = ".boris",
            .rag = null,
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag", "--input", "c", "--quiet" },
            .mode = .rag,
            .input = "c",
            .out = null,
            .rag = "rag",
            .html = null,
            .quiet = true,
        },
        .{
            .args = &.{ "boris", "--rag", "--input=c", "--rag-dir=out-rag" },
            .mode = .rag,
            .input = "c",
            .out = null,
            .rag = "out-rag",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html-dir", "site/out" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "site/out",
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html-dir=x" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "x",
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html", "--html-dir", "custom-dist" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "custom-dist",
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html", "--input", "docs", "--quiet" },
            .mode = .html,
            .input = "docs",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = true,
        },
    };

    for (cases) |c| {
        const o = try parseOptions(c.args);
        try expectEqual(c.mode, o.mode);
        try expectEqualStrings(c.input, o.input_dir);
        try expectEqual(c.quiet, o.quiet);
        if (c.out) |want| {
            try expectEqualStrings(want, o.out_dir.?);
        } else {
            try expect(o.out_dir == null);
        }
        if (c.rag) |want| {
            try expectEqualStrings(want, o.rag_dir.?);
        } else {
            try expect(o.rag_dir == null);
        }
        if (c.html) |want| {
            try expectEqualStrings(want, o.html_dir.?);
        } else {
            try expect(o.html_dir == null);
        }
    }
}

test "parse: conflicts and missing values table" {
    const Case = struct {
        args: []const []const u8,
        err: ParseError,
    };

    const cases = [_]Case{
        // Rule 5: --rag + --no-rag
        .{ .args = &.{ "boris", "--rag", "--no-rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--no-rag", "--rag" }, .err = error.ConflictingFlags },
        // Rule 6: --no-rag + --rag-dir
        .{ .args = &.{ "boris", "--no-rag", "--rag-dir", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--rag-dir", "x", "--no-rag" }, .err = error.ConflictingFlags },
        // Rule 7: explicit --out with RAG selection
        .{ .args = &.{ "boris", "--rag", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--out", "x", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--rag-dir", "r", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--out=x", "--rag-dir=r" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--out", "x", "--rag", "--rag-dir", "r" }, .err = error.ConflictingFlags },
        // HTML exclusive of RAG and explicit --out
        .{ .args = &.{ "boris", "--html", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--rag-dir", "r" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html-dir", "d", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html-dir", "d", "--rag-dir", "r" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html-dir", "d", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--out=x", "--html" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--rag-dir=r", "--html-dir=d" }, .err = error.ConflictingFlags },
        // Rule 8: empty values
        .{ .args = &.{ "boris", "--input", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--out", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--rag-dir", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--html-dir", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--input=" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--out=" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--rag-dir=" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--html-dir=" }, .err = error.EmptyValue },
        // Rule 9: unknown, missing value, positional, duplicates
        .{ .args = &.{ "boris", "--unknown" }, .err = error.UnknownFlag },
        .{ .args = &.{ "boris", "-v" }, .err = error.UnknownFlag },
        .{ .args = &.{ "boris", "--wat" }, .err = error.UnknownFlag },
        .{ .args = &.{ "boris", "--input" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--out" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--rag-dir" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--html-dir" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "content" }, .err = error.UnexpectedPositional },
        .{ .args = &.{ "boris", "extra", "args" }, .err = error.UnexpectedPositional },
        .{ .args = &.{ "boris", "--rag", "--rag" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--no-rag", "--no-rag" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--html", "--html" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--quiet", "--quiet" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--input", "a", "--input", "b" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--out", "a", "--out", "b" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--rag-dir", "a", "--rag-dir", "b" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--html-dir", "a", "--html-dir", "b" }, .err = error.DuplicateFlag },
    };

    for (cases) |c| {
        try expectError(c.err, parseOptions(c.args));
    }
}

test "parse: help short-circuits and does not validate trailing junk" {
    const o = try parseOptions(&.{ "boris", "--help", "--not-a-real-flag", "--rag", "--no-rag" });
    try expect(o.help);

    const o2 = try parseOptions(&.{ "boris", "-h" });
    try expect(o2.help);
}

test "execute: help does not invoke pipeline (dependency injection)" {
    const Spy = struct {
        pipeline_calls: usize = 0,
        help_calls: usize = 0,

        pub fn printHelp(self: *@This()) void {
            self.help_calls += 1;
        }

        pub fn run(self: *@This(), opts: Options) ExitCode {
            _ = opts;
            self.pipeline_calls += 1;
            return .success;
        }
    };

    var spy: Spy = .{};
    const opts = try parseOptions(&.{ "boris", "--help" });
    const code = execute(opts, &spy);
    try expectEqual(ExitCode.success, code);
    try expectEqual(@as(usize, 1), spy.help_calls);
    try expectEqual(@as(usize, 0), spy.pipeline_calls);
}

test "execute: build mode invokes pipeline once" {
    const Spy = struct {
        pipeline_calls: usize = 0,
        last_mode: ?Mode = null,

        pub fn printHelp(self: *@This()) void {
            _ = self;
        }

        pub fn run(self: *@This(), opts: Options) ExitCode {
            self.pipeline_calls += 1;
            self.last_mode = opts.mode;
            return .success;
        }
    };

    var spy: Spy = .{};
    const opts = try parseOptions(&.{ "boris", "--rag-dir", "x" });
    const code = execute(opts, &spy);
    try expectEqual(ExitCode.success, code);
    try expectEqual(@as(usize, 1), spy.pipeline_calls);
    try expectEqual(Mode.rag, spy.last_mode.?);
}

test "runArgs: usage errors exit 2; help exits 0" {
    const Spy = struct {
        pipeline_calls: usize = 0,

        pub fn printHelp(self: *@This()) void {
            _ = self;
        }

        pub fn reportUsage(self: *@This(), err: ParseError, bad_arg: ?[]const u8) void {
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

    var spy: Spy = .{};
    try expectEqual(@as(u8, 0), runArgs(&.{ "boris", "--help" }, &spy));
    try expectEqual(@as(usize, 0), spy.pipeline_calls);

    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--rag", "--no-rag" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--rag", "--out", "x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--html", "--rag" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--html", "--out", "x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--unknown" }, &spy));
    try expectEqual(@as(usize, 0), spy.pipeline_calls);

    try expectEqual(@as(u8, 0), runArgs(&.{ "boris", "--rag-dir", "x" }, &spy));
    try expectEqual(@as(u8, 0), runArgs(&.{ "boris", "--html" }, &spy));
    try expectEqual(@as(usize, 2), spy.pipeline_calls);
}
