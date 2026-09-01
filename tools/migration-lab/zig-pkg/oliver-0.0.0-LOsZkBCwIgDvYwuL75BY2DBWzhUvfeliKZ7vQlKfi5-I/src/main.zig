//! Provisional CLI: a thin adapter over the library for shell integration.
//!
//!     oliver render    --from markdown [--to html|xhtml] < document.md
//!     oliver render    --from textile  [--to html|xhtml] < document.textile
//!     oliver render    --from cooklang [--to html|xhtml] < recipe.cook
//!     oliver serialize --from cooklang < recipe.cook > canonical.cook
//!     oliver scale --from cooklang --factor 2 < recipe.cook > doubled.cook
//!     oliver scale --from cooklang --factor 3/2 < recipe.cook
//!     oliver scale --from cooklang --servings 4 < recipe.cook
//!     oliver menu --from cooklang < plan.menu   # day/meal text dump
//!
//! All parser and renderer semantics live in the library; this file only
//! handles arguments and stdio. It uses the Zig 0.16 `std.process.Init`
//! entry point for a ready allocator and `Io` instance.

const std = @import("std");
const oliver = @import("oliver");
// Injected by build.zig: the package version and the source commit SHA
// (CI passes -Dcommit=$GITHUB_SHA). `oliver --version` prints them so a
// downloaded binary can prove which commit it was built from.
const build_options = @import("build_options");

/// The CLI operation, selected by the subcommand token. Exactly one is
/// required; `parseArgs` rejects a missing, duplicated, or conflicting
/// subcommand (issue #57).
pub const Command = enum {
    render,
    serialize,
    scale,
    menu,
};

/// The full command-line configuration, decided by `parseArgs`. `command`
/// selects the operation; `dialect`/`cooklang` name the input frontend;
/// `factor`/`servings` configure scaling; `profile` selects the renderer
/// serialization (`html` by default, `xhtml` with `--to xhtml`).
pub const RunConfig = struct {
    command: Command,
    dialect: ?oliver.Dialect = null,
    cooklang: bool = false,
    factor_num: ?u32 = null,
    factor_den: ?u32 = null,
    servings_target: ?u32 = null,
    profile: oliver.OutputProfile = .html,
};

/// Parses the argument vector (excluding the program name) into a
/// `RunConfig`. Returns `error.Usage` for any unknown flag, invalid value,
/// missing or duplicated subcommand, or flag that does not belong to the
/// selected command (`--to` is render-only; `--factor`/`--servings` are
/// scale-only), and `error.Help` for `--help`/`-h` (help is a requested
/// outcome, not an error). Pure: no allocator, no I/O, so it is
/// unit-tested directly.
pub fn parseArgs(args: []const []const u8) error{ Usage, Help, Version }!RunConfig {
    var command: ?Command = null;
    var dialect: ?oliver.Dialect = null;
    var cooklang = false;
    var factor_num: ?u32 = null;
    var factor_den: ?u32 = null;
    var servings_target: ?u32 = null;
    var profile: oliver.OutputProfile = .html;
    var saw_to = false;
    var saw_from = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "render")) {
            if (command != null) return error.Usage;
            command = .render;
        } else if (std.mem.eql(u8, arg, "serialize")) {
            if (command != null) return error.Usage;
            command = .serialize;
        } else if (std.mem.eql(u8, arg, "scale")) {
            if (command != null) return error.Usage;
            command = .scale;
        } else if (std.mem.eql(u8, arg, "menu")) {
            if (command != null) return error.Usage;
            command = .menu;
        } else if (std.mem.eql(u8, arg, "--from")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            // A second `--from` would contradict the first (e.g. both
            // `markdown` and `cooklang`), so reject duplicates instead
            // of silently letting the last one win.
            if (saw_from) return error.Usage;
            saw_from = true;
            const value = args[index];
            if (std.mem.eql(u8, value, "markdown")) {
                dialect = .markdown;
            } else if (std.mem.eql(u8, value, "textile")) {
                dialect = .textile;
            } else if (std.mem.eql(u8, value, "cooklang")) {
                cooklang = true;
            } else return error.Usage;
        } else if (std.mem.eql(u8, arg, "--to")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            const value = args[index];
            if (std.mem.eql(u8, value, "html")) {
                profile = .html;
            } else if (std.mem.eql(u8, value, "xhtml")) {
                profile = .xhtml;
            } else return error.Usage;
            saw_to = true;
        } else if (std.mem.eql(u8, arg, "--factor")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            const value = args[index];
            var parts = std.mem.splitScalar(u8, value, '/');
            const num = parts.next() orelse return error.Usage;
            factor_num = std.fmt.parseUnsigned(u32, num, 10) catch return error.Usage;
            // A zero numerator scales everything to nothing and a zero
            // denominator is division by zero; both are degenerate, so
            // both are rejected here (symmetric with `--servings 0`; the
            // library rejects them too, docs/COOKLANG.md §11).
            if (factor_num.? == 0) return error.Usage;
            if (parts.next()) |den| {
                factor_den = std.fmt.parseUnsigned(u32, den, 10) catch return error.Usage;
                if (factor_den.? == 0) return error.Usage;
            }
            if (parts.next() != null) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--servings")) {
            if (index + 1 >= args.len) return error.Usage;
            index += 1;
            const value = args[index];
            servings_target = std.fmt.parseUnsigned(u32, value, 10) catch return error.Usage;
            if (servings_target.? == 0) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.Help;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return error.Version;
        } else return error.Usage;
    }

    // Exactly one subcommand names the operation, and every command
    // needs an input frontend.
    const cmd = command orelse return error.Usage;
    if (!cooklang and dialect == null) return error.Usage;
    // Flags must belong to the command they are given with: `--to`
    // selects the renderer profile (render only), `--factor` /
    // `--servings` configure scaling (scale only), and serialize/scale/
    // menu are Cooklang capabilities only (Markdown/Textile have no
    // canonical form; the shared renderer is the output for those).
    switch (cmd) {
        .render => {
            if (factor_num != null or servings_target != null) return error.Usage;
        },
        .serialize, .menu => {
            if (!cooklang or saw_to or factor_num != null or servings_target != null) return error.Usage;
        },
        .scale => {
            if (!cooklang or saw_to) return error.Usage;
            // Scaling needs exactly one mode: factor or servings.
            if ((factor_num == null) == (servings_target == null)) return error.Usage;
        },
    }
    return .{
        .command = cmd,
        .dialect = dialect,
        .cooklang = cooklang,
        .factor_num = factor_num,
        .factor_den = factor_den,
        .servings_target = servings_target,
        .profile = profile,
    };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next(); // program name
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(gpa);
    while (it.next()) |arg| try args.append(gpa, arg);

    // `--help`/`-h` is a requested outcome: print usage and exit 0.
    // Anything else that `parseArgs` rejects is a real usage error and
    // exits 1 with the same text on stderr.
    const cfg = parseArgs(args.items) catch |err| switch (err) {
        error.Help => {
            printUsage();
            return 0;
        },
        // `--version` is a requested outcome like `--help`: print the
        // version and the embedded source commit, then exit 0.
        error.Version => return version(init),
        error.Usage => return usage(),
    };
    const profile = cfg.profile;

    // Read all of stdin into memory.
    var input = std.ArrayList(u8).empty;
    defer input.deinit(gpa);
    const stdin_file = std.Io.File.stdin();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stdin_file.readStreaming(init.io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try input.appendSlice(gpa, buf[0..n]);
    }

    // Render directly to stdout through a buffered writer.
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(init.io, &out_buf);

    if (cfg.cooklang) {
        var result = oliver.cooklang.parse(gpa, input.items, .{}) catch |err| {
            std.debug.print("oliver: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer result.deinit();
        switch (cfg.command) {
            .serialize => {
                oliver.cooklang_serialize.serialize(gpa, &out_writer.interface, &result.recipe, .{}) catch |err| {
                    std.debug.print("oliver: serialize failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
            },
            .scale => {
                const by: oliver.cooklang_scale.ScaleBy = if (cfg.factor_num) |n|
                    .{ .factor = .{ .num = n, .den = cfg.factor_den orelse 1 } }
                else
                    .{ .servings = cfg.servings_target.? };
                var scaled = oliver.cooklang_scale.scaleRecipe(gpa, &result.recipe, by) catch |err| {
                    std.debug.print("oliver: scale failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                defer scaled.deinit();
                oliver.cooklang_serialize.serialize(gpa, &out_writer.interface, &scaled, .{}) catch |err| {
                    std.debug.print("oliver: serialize failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
            },
            .menu => {
                var m = oliver.cooklang_menu.menuView(gpa, &result.recipe) catch |err| {
                    std.debug.print("oliver: menu view failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
                defer m.deinit();
                oliver.cooklang_menu.writeMenu(&out_writer.interface, &m) catch |err| {
                    std.debug.print("oliver: menu dump failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
            },
            .render => {
                oliver.cooklang_html.render(gpa, &out_writer.interface, &result.recipe, .{ .profile = profile }) catch |err| {
                    std.debug.print("oliver: render failed: {s}\n", .{@errorName(err)});
                    return 1;
                };
            },
        }
    } else {
        const d = cfg.dialect.?;
        var result = oliver.parse(gpa, input.items, d, .{}) catch |err| {
            std.debug.print("oliver: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer result.deinit();
        oliver.html.render(gpa, &out_writer.interface, &result.document, .{ .profile = profile }) catch |err| {
            std.debug.print("oliver: render failed: {s}\n", .{@errorName(err)});
            if (err == error.RawHtmlNotXmlWellFormed) {
                std.debug.print(
                    "oliver: --to xhtml rejects raw HTML that cannot be guaranteed well-formed XML\n" ++
                        "(docs/XHTML.md section 5): remove or escape the raw HTML, or render with --to html.\n",
                    .{},
                );
            }
            return 1;
        };
    }
    out_writer.flush() catch {};
    return 0;
}

fn printUsage() void {
    std.debug.print(
        \\usage: oliver render --from <markdown|textile|cooklang> [--to <html|xhtml>]
        \\       oliver serialize --from cooklang
        \\       oliver scale --from cooklang (--factor <num[/den]> | --servings <n>)
        \\       oliver menu --from cooklang
        \\       oliver --version
        \\
        \\Reads a document from stdin and writes rendered HTML to stdout
        \\(XHTML fragment with --to xhtml). serialize/scale write canonical
        \\Cooklang text; menu writes the day/meal text dump. --version prints
        \\the version and the embedded source commit (CI builds).
        \\
    , .{});
}

fn usage() u8 {
    printUsage();
    return 1;
}

/// `--version` is a requested outcome: print the package version and, for
/// CI builds that embedded one, the exact source commit, then exit 0.
/// Written to stdout (not stderr) so a consumer can parse it: an
/// installer asserts the reported commit equals its pin.
fn version(init: std.process.Init) u8 {
    const text = if (build_options.commit.len == 0)
        std.fmt.allocPrint(init.gpa, "oliver {s}\n", .{build_options.version}) catch return 1
    else
        std.fmt.allocPrint(init.gpa, "oliver {s} (commit {s})\n", .{ build_options.version, build_options.commit }) catch return 1;
    defer init.gpa.free(text);
    std.Io.File.stdout().writeStreamingAll(init.io, text) catch return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// CLI argument parsing tests (pure: no allocator, no I/O).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "cli: default profile is html and --to xhtml selects the xhtml profile" {
    const cfg = try parseArgs(&.{ "render", "--from", "markdown" });
    try testing.expectEqual(oliver.OutputProfile.html, cfg.profile);
    try testing.expectEqual(oliver.Dialect.markdown, cfg.dialect.?);

    const xhtml_cfg = try parseArgs(&.{ "render", "--from", "textile", "--to", "xhtml" });
    try testing.expectEqual(oliver.OutputProfile.xhtml, xhtml_cfg.profile);

    const explicit_html = try parseArgs(&.{ "render", "--from", "markdown", "--to", "html" });
    try testing.expectEqual(oliver.OutputProfile.html, explicit_html.profile);
}

test "cli: --to xhtml reaches the cooklang render path" {
    const cfg = try parseArgs(&.{ "render", "--from", "cooklang", "--to", "xhtml" });
    try testing.expect(cfg.cooklang);
    try testing.expectEqual(oliver.OutputProfile.xhtml, cfg.profile);
    try testing.expectEqual(Command.render, cfg.command);
}

test "cli: missing, duplicated, or conflicting subcommands are rejected" {
    // Regression (issue #57): a bare `--from cooklang` used to be
    // accepted and silently dispatch to render; now the subcommand is
    // required and may appear exactly once.
    try testing.expectError(error.Usage, parseArgs(&.{ "--from", "cooklang" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "render" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "serialize" }));
    try testing.expectError(error.Usage, parseArgs(&.{}));
}

test "cli: flags are scoped to the command that owns them" {
    // `--factor`/`--servings` belong to `scale` only.
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "cooklang", "--factor", "2" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "serialize", "--from", "cooklang", "--factor", "2" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "menu", "--from", "cooklang", "--servings", "4" }));
}

test "cli: --from must name a supported dialect and appear at most once" {
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "asciidoc" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--from", "cooklang" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "cooklang", "--from", "markdown" }));
}

test "cli: --help and -h are requested outcomes, not errors" {
    try testing.expectError(error.Help, parseArgs(&.{"--help"}));
    try testing.expectError(error.Help, parseArgs(&.{ "render", "--from", "markdown", "-h" }));
}

test "cli: --version is a requested outcome, not an error" {
    try testing.expectError(error.Version, parseArgs(&.{"--version"}));
    try testing.expectError(error.Version, parseArgs(&.{ "render", "--from", "markdown", "--version" }));
}

test "cli: invalid --to values and missing values fail clearly" {
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--to", "xml" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "render", "--from", "markdown", "--to" }));
}

test "cli: --to is rejected on the non-HTML cooklang commands" {
    try testing.expectError(error.Usage, parseArgs(&.{ "serialize", "--from", "cooklang", "--to", "xhtml" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2", "--to", "html" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "menu", "--from", "cooklang", "--to", "xhtml" }));
}

test "cli: cooklang-only commands and scale modes keep their rules" {
    try testing.expectError(error.Usage, parseArgs(&.{ "serialize", "--from", "markdown" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2", "--servings", "4" }));
    const ok = try parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "3/2" });
    try testing.expectEqual(@as(u32, 3), ok.factor_num.?);
    try testing.expectEqual(@as(u32, 2), ok.factor_den.?);
}

test "cli: zero scale factors are rejected, not passed to the library" {
    // Regression (issue #55): a zero numerator used to reach
    // `scaleRecipe` and panic with a division by zero. Reject it at the
    // argument layer, symmetric with `--servings 0` and a zero `den`.
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "0" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "0/2" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "scale", "--from", "cooklang", "--factor", "2/0" }));
}
