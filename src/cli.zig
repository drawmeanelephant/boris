//! Typed CLI parser for the Boris product surface (milestone 3).
//!
//! Parses argv into a single canonical `Options` value. Does not open paths,
//! read config files, or consult environment variables.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const target_mod = @import("target.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const RunResult = diagnostic.RunResult;

/// Build mode selected by flags.
pub const Mode = enum {
    /// Emit content-compiler IR under `--out` (default `.boris`).
    ir,
    /// RAG-only export under `--rag-dir` (default `rag`).
    rag,
    /// HTML site render under `--html-dir` (default `dist`). Default bare CLI.
    html,
};

/// Canonical parsed options. Strings are views into argv (or static defaults).
pub const Options = struct {
    /// When true, print help and exit successfully (no pipeline).
    help: bool = false,
    quiet: bool = false,
    mode: Mode = .html,
    /// Content root (default `content`).
    input_dir: []const u8 = "content",
    /// IR output directory. Set for IR mode only (default `.boris`).
    out_dir: ?[]const u8 = null,
    /// RAG corpus directory. Set for RAG mode only (default `rag`).
    rag_dir: ?[]const u8 = null,
    /// HTML output directory. Set for HTML mode only (default `dist`).
    html_dir: ?[]const u8 = null,
    /// Global HTML layout template (default `layouts/main.html`).
    html_layout: []const u8 = "layouts/main.html",
    /// When set, `html_layout` was allocated for `--theme` sugar and must be freed.
    owned_html_layout: bool = false,
    /// Explicit incremental HTML build mode (HTML mode only).
    incremental: bool = false,
    /// Bounded parallel rendering worker count (HTML mode only).
    jobs: usize = 1,
    /// Opt-in local-development watch mode for HTML builds.
    watch: bool = false,
    /// Dynamic target list.
    targets: std.ArrayListUnmanaged(target_mod.TargetSpec) = .{ .items = &.{}, .capacity = 0 },

    pub fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        if (self.owned_html_layout) {
            gpa.free(self.html_layout);
            self.owned_html_layout = false;
        }
        self.targets.deinit(gpa);
    }
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    EmptyValue,
    UnexpectedPositional,
    ConflictingFlags,
    DuplicateFlag,
    InvalidValue,
    OutOfMemory,
};

const default_input_dir = "content";
const default_out_dir = ".boris";
const default_rag_dir = "rag";
const default_html_dir = "dist";
const default_html_layout = "layouts/main.html";

/// Parse argv into `Options`. Does not print, exit, or touch the filesystem.
///
/// `args[0]` is the program name when present (skipped).
/// `--help` / `-h` short-circuit: remaining args are not validated.
pub fn parseOptions(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
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
    var saw_html_layout = false;
    var saw_theme = false;
    var saw_incremental = false;
    var saw_jobs = false;
    var saw_watch = false;
    var jobs: usize = 1;
    var html_layout: []const u8 = default_html_layout;
    var theme_root: ?[]const u8 = null;

    var targets: std.ArrayListUnmanaged(target_mod.TargetSpec) = .{ .items = &.{}, .capacity = 0 };
    errdefer targets.deinit(gpa);
    // Pending --target-layout NAME=PATH applied after targets are known.
    var target_layouts: std.ArrayListUnmanaged(struct { name: []const u8, path: []const u8 }) = .{ .items = &.{}, .capacity = 0 };
    errdefer target_layouts.deinit(gpa);

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
                .targets = .{ .items = &.{}, .capacity = 0 },
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

        if (std.mem.eql(u8, a, "--watch")) {
            if (saw_watch) return error.DuplicateFlag;
            saw_watch = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--target") or std.mem.startsWith(u8, a, "--target=")) {
            const val = try takeValue(args, &i, a, "--target");
            const eq_idx = std.mem.indexOfScalar(u8, val, '=') orelse {
                return error.InvalidValue;
            };
            const name = val[0..eq_idx];
            const output_dir = val[eq_idx + 1 ..];
            if (name.len == 0 or output_dir.len == 0) {
                return error.InvalidValue;
            }
            if (!target_mod.isValidTargetName(name)) {
                return error.InvalidValue;
            }
            for (targets.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return error.DuplicateFlag;
                }
            }
            try targets.append(gpa, .{
                .name = name,
                .output_dir = output_dir,
                .layout_path = null,
            });
            continue;
        }

        if (std.mem.eql(u8, a, "--target-layout") or std.mem.startsWith(u8, a, "--target-layout=")) {
            const val = try takeValue(args, &i, a, "--target-layout");
            const eq_idx = std.mem.indexOfScalar(u8, val, '=') orelse {
                return error.InvalidValue;
            };
            const name = val[0..eq_idx];
            const path = val[eq_idx + 1 ..];
            if (name.len == 0 or path.len == 0) {
                return error.InvalidValue;
            }
            if (!target_mod.isValidTargetName(name)) {
                return error.InvalidValue;
            }
            for (target_layouts.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return error.DuplicateFlag;
                }
            }
            try target_layouts.append(gpa, .{ .name = name, .path = path });
            continue;
        }

        if (std.mem.eql(u8, a, "--jobs") or std.mem.startsWith(u8, a, "--jobs=") or
            std.mem.eql(u8, a, "-j") or std.mem.startsWith(u8, a, "-j=")) {
            if (saw_jobs) return error.DuplicateFlag;
            saw_jobs = true;
            const val_str = if (std.mem.startsWith(u8, a, "-j"))
                try takeValue(args, &i, a, "-j")
            else
                try takeValue(args, &i, a, "--jobs");
            const parsed_val = std.fmt.parseInt(usize, val_str, 10) catch {
                return error.InvalidValue;
            };
            if (parsed_val < 1 or parsed_val > 64) {
                return error.InvalidValue;
            }
            jobs = parsed_val;
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

        if (std.mem.eql(u8, a, "--html-layout") or std.mem.startsWith(u8, a, "--html-layout=")) {
            if (saw_html_layout) return error.DuplicateFlag;
            saw_html_layout = true;
            html_layout = try takeValue(args, &i, a, "--html-layout");
            continue;
        }

        // F9.1: --theme ROOT is sugar for --html-layout ROOT/layouts/main.html
        // (theme asset root is derived from the layout path at compile time).
        if (std.mem.eql(u8, a, "--theme") or std.mem.startsWith(u8, a, "--theme=")) {
            if (saw_theme) return error.DuplicateFlag;
            saw_theme = true;
            theme_root = try takeValue(args, &i, a, "--theme");
            continue;
        }

        if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        }
        return error.UnexpectedPositional;
    }

    // Resolve --theme sugar before mode selection (implies HTML layout path).
    var owned_html_layout = false;
    if (theme_root) |tr| {
        if (tr.len == 0) return error.EmptyValue;
        if (saw_html_layout) return error.ConflictingFlags;
        // Joined path is owned by Options (freed in deinit).
        html_layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{tr});
        owned_html_layout = true;
        saw_html_layout = true;
    }
    errdefer if (owned_html_layout) gpa.free(html_layout);

    const has_explicit_targets = targets.items.len > 0;
    const has_target_layouts = target_layouts.items.len > 0;
    // Explicit HTML selectors (not the bare default).
    const explicit_html = saw_html or saw_html_dir or has_explicit_targets or saw_html_layout or has_target_layouts or saw_theme;
    const wants_rag = saw_rag or saw_rag_dir;
    // Explicit IR: --out and/or --no-rag (bare CLI is HTML, not IR).
    const wants_ir = saw_out or saw_no_rag;

    // --- conflict matrix ---------------------------------------------------
    if (saw_rag and saw_no_rag) return error.ConflictingFlags;
    if (saw_no_rag and saw_rag_dir) return error.ConflictingFlags;
    // Explicit --out must never be combined with RAG-only selection.
    if (saw_out and wants_rag) return error.ConflictingFlags;
    // Explicit HTML selectors own the output destination; refuse IR/RAG flags.
    if (explicit_html and (wants_rag or saw_out)) {
        return error.ConflictingFlags;
    }
    // HTML-only options conflict with IR or RAG selection (default HTML is fine).
    if ((saw_jobs or saw_watch or saw_incremental) and (wants_ir or wants_rag)) {
        return error.ConflictingFlags;
    }
    // Target conflict rules
    if (has_explicit_targets and saw_html_dir) return error.ConflictingFlags;
    // --target-layout attaches to a named --target, or to the synthetic "default"
    // target on bare HTML / --html / --html-dir. Unknown layout names are rejected
    // after the default target is synthesized (InvalidValue). Combined with --out
    // or RAG selectors, has_target_layouts forces explicit_html and hits the
    // HTML-vs-IR/RAG conflict above when --out / --rag / --rag-dir is present.

    // Mode selection:
    // 1. Explicit HTML flags / --target / --target-layout → HTML
    // 2. --rag / --rag-dir → RAG-only
    // 3. --out / --no-rag → IR
    // 4. Default (no mode flags) → HTML site under dist/
    const mode: Mode = if (explicit_html)
        .html
    else if (wants_rag)
        .rag
    else if (wants_ir)
        .ir
    else
        .html;

    // Single-target HTML (bare CLI, --html, or --html-dir) maps to target "default".
    // --target-layout NAME=PATH may attach to this synthetic target.
    if (mode == .html and !has_explicit_targets) {
        try targets.append(gpa, .{
            .name = "default",
            .output_dir = if (saw_html_dir) html_dir else default_html_dir,
            .layout_path = null,
        });
    }

    // Apply --target-layout NAME=PATH onto matching targets. Flag order relative
    // to --target does not matter (layouts are collected first, applied here).
    for (target_layouts.items) |tl| {
        var found = false;
        for (targets.items) |*t| {
            if (std.mem.eql(u8, t.name, tl.name)) {
                if (t.layout_path != null) return error.DuplicateFlag;
                t.layout_path = tl.path;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidValue;
    }
    target_layouts.deinit(gpa);

    // Canonical target order: equivalent --target argv permutations produce the
    // same Options.targets sequence (sorted by name). Execution/diagnostics use
    // the same order via validateTargets.
    if (targets.items.len > 1) {
        target_mod.sortTargetSpecsByName(targets.items);
    }

    return switch (mode) {
        .ir => .{
            .help = false,
            .quiet = quiet,
            .mode = .ir,
            .input_dir = input_dir,
            .out_dir = out_dir,
            .rag_dir = null,
            .html_dir = null,
            .targets = targets,
        },
        .rag => .{
            .help = false,
            .quiet = quiet,
            .mode = .rag,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = rag_dir,
            .html_dir = null,
            .targets = targets,
        },
        .html => .{
            .help = false,
            .quiet = quiet,
            .mode = .html,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = null,
            .html_dir = if (has_explicit_targets) null else html_dir,
            .html_layout = html_layout,
            .owned_html_layout = owned_html_layout,
            .incremental = saw_incremental or saw_watch,
            .jobs = jobs,
            .watch = saw_watch,
            .targets = targets,
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
        \\Boris — Zig content compiler (HTML site + IR + optional RAG)
        \\
        \\Usage: boris [options]
        \\
        \\Modes:
        \\  (default)           HTML site → pages under dist/ (content/ + layouts/main.html)
        \\  --html              Explicit HTML site mode → --html-dir (default dist)
        \\  --html-dir <DIR>    HTML site mode with output directory DIR
        \\  --target NAME=DIR   HTML multi-target mode (repeatable; order-independent); implies HTML
        \\  --out <DIR>         IR mode → write JSON under DIR (default .boris when --no-rag)
        \\  --no-rag            Explicit IR mode (JSON under --out, default .boris)
        \\  --rag               RAG-only mode → corpus under --rag-dir (default rag)
        \\  --rag-dir <DIR>     RAG-only mode with output directory DIR
        \\
        \\Options:
        \\  --input <DIR>       Content root (default: content)
        \\  --out <DIR>         IR output directory (selects IR mode; default: .boris)
        \\  --rag-dir <DIR>     RAG corpus directory (implies RAG-only; default: rag)
        \\  --html-dir <DIR>    HTML output directory (implies HTML; default: dist)
        \\  --html-layout PATH  Global layout template (default: layouts/main.html)
        \\  --theme ROOT        Theme root sugar → ROOT/layouts/main.html (+ managed assets/)
        \\  --target NAME=DIR   Named HTML output root (repeatable; exclusive with --html-dir)
        \\  --target-layout N=P Per-target layout (NAME=PATH; may precede or follow --target)
        \\  --incremental       Content-addressed incremental HTML rendering (HTML mode)
        \\  --watch             Local-development watch mode for HTML builds (implies --incremental)
        \\  --jobs N, -j N      Bounded parallel HTML page workers (1–64; HTML mode; default 1; smoke-validated)
        \\  --quiet             Suppress progress + diagnostic stderr (exit codes/artifacts unchanged)
        \\  -h, --help          Show this help and exit 0
        \\
        \\HTML artifacts (success; Apex + layout splice):
        \\  <html-dir>/**/*.html   or   <each-target-dir>/**/*.html
        \\  <target-dir>/.boris-cache/manifest.json  (with --incremental / --watch)
        \\  Staging: <target-dir>.boris-stage (ephemeral; committed only on full target success)
        \\
        \\IR artifacts (success; --out or --no-rag):
        \\  <out>/manifest.json  <out>/graph.json  <out>/build-report.json
        \\
        \\RAG artifacts (success; same graph validation as IR):
        \\  INDEX.md  UPLOAD-GUIDE.md  catalog.jsonl  catalog_meta.json
        \\  system/**  content/pages/**  graph/entity-catalog.md  graph/relations.md
        \\
        \\Conflicts (exit 2):
        \\  --rag with --no-rag
        \\  --no-rag with --rag-dir
        \\  explicit --out with --rag or --rag-dir
        \\  --html / --html-dir / --target / --target-layout with --rag, --rag-dir, or explicit --out
        \\  --target with --html-dir
        \\  --watch, --incremental, or --jobs with IR (--out / --no-rag) or RAG
        \\  Invalid target names, duplicate names, output collisions, workspace escape,
        \\  content/layout overlap, unknown --target-layout name
        \\
        \\Exit codes: 0 success, 1 content validation, 2 usage, 3 I/O/system
        \\
        \\Note: Bare `boris` builds HTML under dist/ as target "default". Use --out for JSON IR.
        \\      --html / --html-dir / bare CLI map to a single target named "default".
        \\      Equivalent --target / --target-layout permutations yield the same config
        \\      (targets sorted by name). --target works with --watch and --incremental.
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
        error.InvalidValue => {
            if (bad_arg) |a| {
                std.debug.print("error: invalid value for {s}\n", .{a});
            } else {
                std.debug.print("error: invalid option value\n", .{});
            }
        },
        error.OutOfMemory => {
            std.debug.print("error: out of memory\n", .{});
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
            std.mem.eql(u8, a, "--incremental") or
            std.mem.eql(u8, a, "--watch"))
        {
            continue;
        }
        if (std.mem.eql(u8, a, "--input") or
            std.mem.eql(u8, a, "--out") or
            std.mem.eql(u8, a, "--rag-dir") or
            std.mem.eql(u8, a, "--html-dir") or
            std.mem.eql(u8, a, "--html-layout") or
            std.mem.eql(u8, a, "--target") or
            std.mem.eql(u8, a, "--target-layout") or
            std.mem.eql(u8, a, "--jobs") or
            std.mem.eql(u8, a, "-j"))
        {
            // Value may be missing or empty — report the flag name.
            return a;
        }
        if (std.mem.startsWith(u8, a, "--input=") or
            std.mem.startsWith(u8, a, "--out=") or
            std.mem.startsWith(u8, a, "--rag-dir=") or
            std.mem.startsWith(u8, a, "--html-dir=") or
            std.mem.startsWith(u8, a, "--html-layout=") or
            std.mem.startsWith(u8, a, "--target=") or
            std.mem.startsWith(u8, a, "--target-layout=") or
            std.mem.startsWith(u8, a, "--jobs=") or
            std.mem.startsWith(u8, a, "-j="))
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
    const gpa = if (@hasField(@TypeOf(runner.*), "gpa")) runner.gpa else std.testing.allocator;
    var opts = parseOptions(gpa, args) catch |err| {
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
    defer opts.deinit(gpa);
    return execute(opts, runner).int();
}

// --- tests -----------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "parse: default is HTML mode" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris" });
    defer o.deinit(std.testing.allocator);
    try expect(!o.help);
    try expect(!o.quiet);
    try expectEqual(Mode.html, o.mode);
    try expectEqualStrings(default_input_dir, o.input_dir);
    try expect(o.out_dir == null);
    try expect(o.rag_dir == null);
    try expectEqualStrings(default_html_dir, o.html_dir.?);
    try expectEqual(@as(usize, 1), o.targets.items.len);
    try expectEqualStrings("default", o.targets.items[0].name);
    try expectEqualStrings(default_html_dir, o.targets.items[0].output_dir);
}

test "parse: --out selects IR mode" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--out", ".boris" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.ir, o.mode);
    try expectEqualStrings(".boris", o.out_dir.?);
    try expect(o.html_dir == null);
    try expect(o.rag_dir == null);
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
        jobs: usize = 1,
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
        .{
            .args = &.{ "boris", "--html", "--jobs", "4" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = false,
            .jobs = 4,
        },
        .{
            .args = &.{ "boris", "--html-dir", "custom-dist", "-j=8" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "custom-dist",
            .quiet = false,
            .jobs = 8,
        },
        // HTML-only flags without --html are valid under the HTML default.
        .{
            .args = &.{ "boris", "--jobs", "4" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = false,
            .jobs = 4,
        },
        .{
            .args = &.{ "boris", "--input", "docs", "--quiet" },
            .mode = .html,
            .input = "docs",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = true,
        },
        .{
            .args = &.{ "boris", "--out", ".boris" },
            .mode = .ir,
            .input = "content",
            .out = ".boris",
            .rag = null,
            .html = null,
            .quiet = false,
        },
    };

    for (cases) |c| {
        var o = try parseOptions(std.testing.allocator, c.args);
        errdefer o.deinit(std.testing.allocator);
        try expectEqual(c.mode, o.mode);
        try expectEqualStrings(c.input, o.input_dir);
        try expectEqual(c.quiet, o.quiet);
        try expectEqual(c.jobs, o.jobs);
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
        o.deinit(std.testing.allocator);
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
        // Jobs option tests (valid alone under HTML default; conflict with IR/RAG)
        .{ .args = &.{ "boris", "--jobs", "4", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--jobs", "4", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--jobs", "4", "--no-rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--jobs", "0" }, .err = error.InvalidValue },
        .{ .args = &.{ "boris", "--html", "--jobs", "65" }, .err = error.InvalidValue },
        .{ .args = &.{ "boris", "--html", "--jobs", "abc" }, .err = error.InvalidValue },
        .{ .args = &.{ "boris", "--html", "--jobs", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--html", "--jobs=" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--html", "--jobs" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--html", "-j" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--html", "--jobs", "4", "--jobs", "8" }, .err = error.DuplicateFlag },
        // Watch option tests (valid alone under HTML default; conflict with IR/RAG)
        .{ .args = &.{ "boris", "--watch", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--watch", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--watch", "--no-rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--watch", "--watch" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--html", "--watch", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--watch", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--incremental", "--out", "x" }, .err = error.ConflictingFlags },
    };

    for (cases) |c| {
        try expectError(c.err, parseOptions(std.testing.allocator, c.args));
    }
}

test "parse: --watch with HTML implies incremental" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--html", "--watch" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o.mode);
    try expect(o.watch);
    try expect(o.incremental);
    try expectEqualStrings(default_html_dir, o.html_dir.?);

    var o2 = try parseOptions(std.testing.allocator, &.{ "boris", "--html-dir", "site", "--watch", "--jobs", "2" });
    defer o2.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o2.mode);
    try expect(o2.watch);
    try expect(o2.incremental);
    try expectEqual(@as(usize, 2), o2.jobs);
    try expectEqualStrings("site", o2.html_dir.?);

    // Explicit --incremental with --watch remains valid
    var o3 = try parseOptions(std.testing.allocator, &.{ "boris", "--html", "--watch", "--incremental" });
    defer o3.deinit(std.testing.allocator);
    try expect(o3.watch);
    try expect(o3.incremental);

    // Bare --watch is valid under HTML default
    var o4 = try parseOptions(std.testing.allocator, &.{ "boris", "--watch" });
    defer o4.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o4.mode);
    try expect(o4.watch);
    try expect(o4.incremental);
}

test "parse: help short-circuits and does not validate trailing junk" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--help", "--not-a-real-flag", "--rag", "--no-rag" });
    defer o.deinit(std.testing.allocator);
    try expect(o.help);

    var o2 = try parseOptions(std.testing.allocator, &.{ "boris", "-h" });
    defer o2.deinit(std.testing.allocator);
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
    var opts = try parseOptions(std.testing.allocator, &.{ "boris", "--help" });
    defer opts.deinit(std.testing.allocator);
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
    var opts = try parseOptions(std.testing.allocator, &.{ "boris", "--rag-dir", "x" });
    defer opts.deinit(std.testing.allocator);
    const code = execute(opts, &spy);
    try expectEqual(ExitCode.success, code);
    try expectEqual(@as(usize, 1), spy.pipeline_calls);
    try expectEqual(Mode.rag, spy.last_mode.?);
}

test "runArgs: usage errors exit 2; help exits 0" {
    const Spy = struct {
        gpa: std.mem.Allocator = std.testing.allocator,
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

test "parse: --target flag parsing and conflict checks" {
    // Normal multi-target parsing
    {
        var o = try parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod", "--target", "stage=dist/stage" });
        defer o.deinit(std.testing.allocator);
        try expectEqual(Mode.html, o.mode);
        try expectEqual(@as(usize, 2), o.targets.items.len);
        try expectEqualStrings("prod", o.targets.items[0].name);
        try expectEqualStrings("dist/prod", o.targets.items[0].output_dir);
        try expectEqualStrings("stage", o.targets.items[1].name);
        try expectEqualStrings("dist/stage", o.targets.items[1].output_dir);
    }

    // Conflict with --html-dir
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod", "--html-dir", "custom" }));

    // Conflict with --out
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod", "--out", "x" }));

    // Conflict with --rag
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod", "--rag" }));

    // Invalid values
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target", "=dist/prod" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod/site=dist" }));

    // Duplicate target flag
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod1", "--target", "prod=dist/prod2" }));

    // Global + per-target layouts
    {
        var o = try parseOptions(std.testing.allocator, &.{
            "boris",
            "--target", "prod=dist/prod",
            "--target", "stage=dist/stage",
            "--html-layout", "layouts/main.html",
            "--target-layout", "stage=layouts/stage.html",
        });
        defer o.deinit(std.testing.allocator);
        try expectEqualStrings("layouts/main.html", o.html_layout);
        try expect(o.targets.items[0].layout_path == null);
        try expectEqualStrings("layouts/stage.html", o.targets.items[1].layout_path.?);
    }

    // Unknown target-layout name
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{
        "boris", "--target", "prod=dist/prod", "--target-layout", "nope=layouts/x.html",
    }));
}

test "findBadArg reports --target" {
    try expectEqualStrings("--target", findBadArg(&.{ "boris", "--target" }).?);
    try expectEqualStrings("--target=", findBadArg(&.{ "boris", "--target=" }).?);
    try expectEqualStrings("--target=bad", findBadArg(&.{ "boris", "--target=bad" }).?);
    try expectEqualStrings("--html-layout", findBadArg(&.{ "boris", "--html-layout" }).?);
    try expectEqualStrings("--target-layout", findBadArg(&.{ "boris", "--target-layout" }).?);
}

test "parse: --theme sugar selects theme layouts/main.html" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris", "--theme", "experimental-theme",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o.mode);
    try expectEqualStrings("experimental-theme/layouts/main.html", o.html_layout);
    try expect(o.owned_html_layout);

    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{
        "boris", "--theme", "t", "--html-layout", "layouts/main.html",
    }));
}


test "parse: equivalent --target order yields equivalent configuration" {
    var a = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target", "stage=dist/stage",
        "--target", "prod=dist/prod",
        "--target-layout", "stage=layouts/stage.html",
    });
    defer a.deinit(std.testing.allocator);
    var b = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target", "prod=dist/prod",
        "--target", "stage=dist/stage",
        "--target-layout", "stage=layouts/stage.html",
    });
    defer b.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 2), a.targets.items.len);
    try expectEqual(@as(usize, 2), b.targets.items.len);
    try expectEqualStrings("prod", a.targets.items[0].name);
    try expectEqualStrings("stage", a.targets.items[1].name);
    try expectEqualStrings(a.targets.items[0].name, b.targets.items[0].name);
    try expectEqualStrings(a.targets.items[1].name, b.targets.items[1].name);
    try expectEqualStrings(a.targets.items[0].output_dir, b.targets.items[0].output_dir);
    try expectEqualStrings(a.targets.items[1].output_dir, b.targets.items[1].output_dir);
    try expect(a.targets.items[0].layout_path == null);
    try expect(b.targets.items[0].layout_path == null);
    try expectEqualStrings("layouts/stage.html", a.targets.items[1].layout_path.?);
    try expectEqualStrings(a.targets.items[1].layout_path.?, b.targets.items[1].layout_path.?);
}

test "parse: --target-layout order relative to --target is independent" {
    var before = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target-layout", "prod=layouts/prod.html",
        "--target", "prod=dist/prod",
        "--target", "stage=dist/stage",
    });
    defer before.deinit(std.testing.allocator);
    var after = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target", "stage=dist/stage",
        "--target", "prod=dist/prod",
        "--target-layout", "prod=layouts/prod.html",
    });
    defer after.deinit(std.testing.allocator);

    try expectEqualStrings("prod", before.targets.items[0].name);
    try expectEqualStrings("stage", before.targets.items[1].name);
    try expectEqualStrings("layouts/prod.html", before.targets.items[0].layout_path.?);
    try expect(before.targets.items[1].layout_path == null);
    try expectEqualStrings(before.targets.items[0].name, after.targets.items[0].name);
    try expectEqualStrings(before.targets.items[0].layout_path.?, after.targets.items[0].layout_path.?);
    try expectEqualStrings(before.targets.items[1].output_dir, after.targets.items[1].output_dir);
}

test "parse: bare HTML and --html map to default target; --target-layout attaches" {
    var bare = try parseOptions(std.testing.allocator, &.{"boris"});
    defer bare.deinit(std.testing.allocator);
    try expectEqual(Mode.html, bare.mode);
    try expectEqual(@as(usize, 1), bare.targets.items.len);
    try expectEqualStrings("default", bare.targets.items[0].name);
    try expectEqualStrings(default_html_dir, bare.targets.items[0].output_dir);

    var html = try parseOptions(std.testing.allocator, &.{ "boris", "--html", "--html-dir", "site-out" });
    defer html.deinit(std.testing.allocator);
    try expectEqualStrings("default", html.targets.items[0].name);
    try expectEqualStrings("site-out", html.targets.items[0].output_dir);

    var layout_only = try parseOptions(std.testing.allocator, &.{
        "boris", "--target-layout", "default=layouts/alt.html",
    });
    defer layout_only.deinit(std.testing.allocator);
    try expectEqual(Mode.html, layout_only.mode);
    try expectEqualStrings("default", layout_only.targets.items[0].name);
    try expectEqualStrings("layouts/alt.html", layout_only.targets.items[0].layout_path.?);
    try expectEqualStrings(default_html_dir, layout_only.targets.items[0].output_dir);
}

test "parse: --target with --watch and --incremental" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target", "prod=dist/prod",
        "--target", "stage=dist/stage",
        "--watch",
        "--incremental",
        "--jobs", "2",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o.mode);
    try expect(o.watch);
    try expect(o.incremental);
    try expectEqual(@as(usize, 2), o.jobs);
    try expectEqual(@as(usize, 2), o.targets.items.len);
    try expectEqualStrings("prod", o.targets.items[0].name);
    try expectEqualStrings("stage", o.targets.items[1].name);
    try expect(o.html_dir == null);

    var w = try parseOptions(std.testing.allocator, &.{
        "boris", "--target=a=dist/a", "--watch",
    });
    defer w.deinit(std.testing.allocator);
    try expect(w.watch);
    try expect(w.incremental);
    try expectEqualStrings("a", w.targets.items[0].name);
}

test "runArgs: invalid target parse errors exit 2" {
    const Spy = struct {
        gpa: std.mem.Allocator = std.testing.allocator,
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
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "bad/name=dist" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod=dist/p", "--target", "prod=dist/q" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod=dist/p", "--html-dir", "x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod=dist/p", "--out", "x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod=dist/p", "--target-layout", "nope=x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target-layout", "nope=layouts/x.html" }, &spy));
    try expectEqual(@as(usize, 0), spy.pipeline_calls);

    try expectEqual(@as(u8, 0), runArgs(&.{
        "boris", "--target", "b=dist/b", "--target", "a=dist/a", "--watch", "--incremental",
    }, &spy));
    try expectEqual(@as(usize, 1), spy.pipeline_calls);
}
