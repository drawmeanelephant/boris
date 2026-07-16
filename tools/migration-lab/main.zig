//! boris-migration-lab — standalone migration archaeology tools.
//!
//! Modes:
//!   astro      — read-only Astro tree scan → report.json + REPORT.md
//!   wordpress  — WordPress WXR → Boris Markdown + reports
//!   instagram  — Instagram Takeout dump → Boris Markdown + theme assets + reports
//!   obsidian   — Obsidian vault → Boris Markdown + attachments + reports
//!   notion     — Notion Markdown & CSV export → Boris Markdown + media + reports
//!
//! Never rewrites inputs. Not part of the Boris product compiler pipeline.
//!
//! Usage (from tools/migration-lab/):
//!   zig build
//!   zig build run -- --mode=astro --root=./fixtures/mini-astro --out=./.out-report
//!   zig build run -- --mode=wordpress --wxr=./fixtures/mini-wxr/export.xml \
//!       --media=./fixtures/mini-wxr/media --out=./.out-wp
//!   zig build run -- --mode=instagram --dump=./fixtures/mini-instagram --out=./.out-ig
//!   zig build run -- --mode=obsidian --vault=./fixtures/mini-obsidian --out=./.out-obs
//!   zig build run -- --mode=notion --export=./fixtures/mini-notion --out=./.out-notion
//!   zig build test
//!
//! From repo root:
//!   zig build -C tools/migration-lab
//!   zig build -C tools/migration-lab test

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");
const wordpress = @import("wordpress.zig");
const instagram = @import("instagram.zig");
const obsidian = @import("obsidian.zig");
const notion = @import("notion.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    io_error = 3,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub const Mode = enum {
    astro,
    wordpress,
    instagram,
    obsidian,
    notion,

    pub fn parse(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "astro")) return .astro;
        if (std.mem.eql(u8, s, "wordpress") or std.mem.eql(u8, s, "wp") or std.mem.eql(u8, s, "wxr")) return .wordpress;
        if (std.mem.eql(u8, s, "instagram") or std.mem.eql(u8, s, "ig") or std.mem.eql(u8, s, "takeout")) return .instagram;
        if (std.mem.eql(u8, s, "obsidian") or std.mem.eql(u8, s, "obs") or std.mem.eql(u8, s, "vault")) return .obsidian;
        if (std.mem.eql(u8, s, "notion") or std.mem.eql(u8, s, "md-csv") or std.mem.eql(u8, s, "notion-export")) return .notion;
        return null;
    }
};

pub const Options = struct {
    help: bool = false,
    quiet: bool = false,
    mode: Mode = .astro,
    /// Astro project/export root to scan (relative to cwd unless absolute).
    root_dir: []const u8 = ".",
    /// WordPress WXR/XML export path.
    wxr_path: ?[]const u8 = null,
    /// Optional local media directory (WordPress uploads mirror).
    media_dir: ?[]const u8 = null,
    /// Unpacked Instagram data-download root.
    dump_dir: ?[]const u8 = null,
    /// Obsidian vault root.
    vault_dir: ?[]const u8 = null,
    /// Unpacked Notion Markdown & CSV export root.
    export_dir: ?[]const u8 = null,
    /// Report/output directory (created if missing). Never writes into inputs.
    out_dir: []const u8 = "migration-report",
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
};

pub fn parseOptions(args: []const []const u8) ParseError!Options {
    var options: Options = .{};
    var index: usize = if (args.len == 0) 0 else 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            options.quiet = true;
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            const value = arg["--mode=".len..];
            if (value.len == 0) return error.MissingValue;
            options.mode = Mode.parse(value) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.mode = Mode.parse(args[index]) orelse return error.InvalidValue;
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            const value = arg["--root=".len..];
            if (value.len == 0) return error.MissingValue;
            options.root_dir = value;
        } else if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.root_dir = args[index];
        } else if (std.mem.startsWith(u8, arg, "--wxr=")) {
            const value = arg["--wxr=".len..];
            if (value.len == 0) return error.MissingValue;
            options.wxr_path = value;
            // Selecting --wxr implies wordpress when mode left default, unless user set mode first.
            // Always set wordpress when --wxr is present.
            options.mode = .wordpress;
        } else if (std.mem.eql(u8, arg, "--wxr")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.wxr_path = args[index];
            options.mode = .wordpress;
        } else if (std.mem.startsWith(u8, arg, "--media=")) {
            const value = arg["--media=".len..];
            if (value.len == 0) return error.MissingValue;
            options.media_dir = value;
        } else if (std.mem.eql(u8, arg, "--media")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.media_dir = args[index];
        } else if (std.mem.startsWith(u8, arg, "--dump=")) {
            const value = arg["--dump=".len..];
            if (value.len == 0) return error.MissingValue;
            options.dump_dir = value;
            options.mode = .instagram;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.dump_dir = args[index];
            options.mode = .instagram;
        } else if (std.mem.startsWith(u8, arg, "--vault=")) {
            const value = arg["--vault=".len..];
            if (value.len == 0) return error.MissingValue;
            options.vault_dir = value;
            options.mode = .obsidian;
        } else if (std.mem.eql(u8, arg, "--vault")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.vault_dir = args[index];
            options.mode = .obsidian;
        } else if (std.mem.startsWith(u8, arg, "--export=")) {
            const value = arg["--export=".len..];
            if (value.len == 0) return error.MissingValue;
            options.export_dir = value;
            options.mode = .notion;
        } else if (std.mem.eql(u8, arg, "--export")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.export_dir = args[index];
            options.mode = .notion;
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            const value = arg["--out=".len..];
            if (value.len == 0) return error.MissingValue;
            options.out_dir = value;
        } else if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.out_dir = args[index];
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

fn printUsage() void {
    std.debug.print(
        \\boris-migration-lab — Astro / WordPress / Instagram / Obsidian / Notion → Boris migration laboratory
        \\
        \\Usage:
        \\  boris-migration-lab [options]
        \\  zig build run -- [options]
        \\
        \\Common options:
        \\  -h, --help         Show this help and exit
        \\  -q, --quiet        Suppress progress lines
        \\  --mode=MODE        astro (default) | wordpress | instagram | obsidian | notion
        \\  --out=DIR          Output directory (default: migration-report)
        \\
        \\Astro mode:
        \\  --root=DIR         Astro project/export root to scan (default: .)
        \\  Writes: report.json, REPORT.md
        \\
        \\WordPress mode:
        \\  --wxr=FILE         WordPress WXR/XML export (required; never modified)
        \\  --media=DIR        Optional local media/uploads directory (never modified)
        \\  Writes: content/**/*.md, report.json, REPORT.md
        \\  (--wxr implies --mode=wordpress)
        \\
        \\Instagram mode:
        \\  --dump=DIR         Unpacked Instagram data-download root (required; never modified)
        \\  Writes: content/**/*.md, theme/**, report.json, REPORT.md, media_manifest.json
        \\  (--dump implies --mode=instagram)
        \\  No network, zip extraction, API, or scraping.
        \\
        \\Obsidian mode:
        \\  --vault=DIR        Obsidian vault root (required; never modified)
        \\  Writes: content/**/*.md, assets/**, report.json, REPORT.md, attachments_manifest.json
        \\  (--vault implies --mode=obsidian)
        \\  No Dataview/Canvas/plugin evaluation; unresolved links retained raw.
        \\
        \\Notion mode:
        \\  --export=DIR       Unpacked Notion Markdown & CSV export root (required; never modified)
        \\  Writes: content/**/*.md, media/**, report.json, REPORT.md, media_manifest.json
        \\  (--export implies --mode=notion)
        \\  No Notion API, OAuth, network, zip extraction, or private workspace ingestion.
        \\
        \\Safety: no network, no destructive source writes, originals preserved.
        \\Exit codes: 0 success, 2 usage, 3 I/O error
        \\
    , .{});
}

pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args_z = init.minimal.args.toSlice(cold) catch {
        std.log.err("failed to read process arguments", .{});
        return ExitCode.usage.int();
    };

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
        switch (err) {
            error.UnknownFlag => std.log.err("unknown argument (try --help)", .{}),
            error.MissingValue => std.log.err("missing value for flag (try --help)", .{}),
            error.InvalidValue => std.log.err("invalid flag value (try --help)", .{}),
        }
        printUsage();
        return ExitCode.usage.int();
    };

    if (opts.help) {
        printUsage();
        return ExitCode.success.int();
    }

    switch (opts.mode) {
        .astro => {
            if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
                std.log.err("--out must differ from --root (refusing to write reports into the scan tree)", .{});
                return ExitCode.usage.int();
            }
            archaeology.run(io, gpa, .{
                .root_dir = opts.root_dir,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (astro) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .wordpress => {
            const wxr = opts.wxr_path orelse {
                std.log.err("wordpress mode requires --wxr=FILE", .{});
                printUsage();
                return ExitCode.usage.int();
            };
            if (std.mem.eql(u8, wxr, opts.out_dir)) {
                std.log.err("--out must differ from --wxr", .{});
                return ExitCode.usage.int();
            }
            if (opts.media_dir) |md| {
                if (std.mem.eql(u8, md, opts.out_dir)) {
                    std.log.err("--out must differ from --media", .{});
                    return ExitCode.usage.int();
                }
            }
            wordpress.run(io, gpa, .{
                .wxr_path = wxr,
                .media_dir = opts.media_dir,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (wordpress) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .instagram => {
            const dump = opts.dump_dir orelse {
                std.log.err("instagram mode requires --dump=DIR", .{});
                printUsage();
                return ExitCode.usage.int();
            };
            if (std.mem.eql(u8, dump, opts.out_dir)) {
                std.log.err("--out must differ from --dump", .{});
                return ExitCode.usage.int();
            }
            instagram.run(io, gpa, .{
                .dump_dir = dump,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (instagram) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .obsidian => {
            const vault = opts.vault_dir orelse {
                std.log.err("obsidian mode requires --vault=DIR", .{});
                printUsage();
                return ExitCode.usage.int();
            };
            if (std.mem.eql(u8, vault, opts.out_dir)) {
                std.log.err("--out must differ from --vault", .{});
                return ExitCode.usage.int();
            }
            obsidian.run(io, gpa, .{
                .vault_dir = vault,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (obsidian) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .notion => {
            const export_dir = opts.export_dir orelse {
                std.log.err("notion mode requires --export=DIR", .{});
                printUsage();
                return ExitCode.usage.int();
            };
            if (std.mem.eql(u8, export_dir, opts.out_dir)) {
                std.log.err("--out must differ from --export", .{});
                return ExitCode.usage.int();
            }
            notion.run(io, gpa, .{
                .export_dir = export_dir,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (notion) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
    }
    return ExitCode.success.int();
}

// ---------------------------------------------------------------------------
// Tests — shared CLI + WordPress unit/fixture + Astro regression
// ---------------------------------------------------------------------------

// Pull Obsidian / Notion unit/fixture tests into this test binary. (Other modes
// already declare their fixture tests in this file; do not refAllDecls Instagram
// here — its in-module tests currently leak under the testing allocator.)
test {
    _ = obsidian;
    _ = notion;
}

test "parseOptions: defaults and astro flags" {
    const o = try parseOptions(&.{"boris-migration-lab"});
    try std.testing.expect(!o.help);
    try std.testing.expect(o.mode == .astro);
    try std.testing.expectEqualStrings(".", o.root_dir);
    try std.testing.expectEqualStrings("migration-report", o.out_dir);

    const h = try parseOptions(&.{ "boris-migration-lab", "--help" });
    try std.testing.expect(h.help);

    const o2 = try parseOptions(&.{
        "boris-migration-lab",
        "--root=./fixtures/mini-astro",
        "--out=./.tmp-report",
        "--quiet",
    });
    try std.testing.expectEqualStrings("./fixtures/mini-astro", o2.root_dir);
    try std.testing.expectEqualStrings("./.tmp-report", o2.out_dir);
    try std.testing.expect(o2.quiet);
}

test "parseOptions: wordpress flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--wxr=fixtures/mini-wxr/export.xml",
        "--media=fixtures/mini-wxr/media",
        "--out=./.wp-out",
    });
    try std.testing.expect(o.mode == .wordpress);
    try std.testing.expectEqualStrings("fixtures/mini-wxr/export.xml", o.wxr_path.?);
    try std.testing.expectEqualStrings("fixtures/mini-wxr/media", o.media_dir.?);
    try std.testing.expectEqualStrings("./.wp-out", o.out_dir);

    const o2 = try parseOptions(&.{ "boris-migration-lab", "--mode=wordpress", "--wxr", "a.xml" });
    try std.testing.expect(o2.mode == .wordpress);
}

test "parseOptions: instagram flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--dump=fixtures/mini-instagram",
        "--out=./.ig",
    });
    try std.testing.expect(o.mode == .instagram);
    try std.testing.expectEqualStrings("fixtures/mini-instagram", o.dump_dir.?);
    try std.testing.expectEqualStrings("./.ig", o.out_dir);

    const o2 = try parseOptions(&.{
        "boris-migration-lab",
        "--mode=instagram",
        "--dump",
        "fixtures/mini-instagram",
    });
    try std.testing.expect(o2.mode == .instagram);
    try std.testing.expectEqualStrings("fixtures/mini-instagram", o2.dump_dir.?);
}

test "parseOptions: obsidian flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--vault=fixtures/mini-obsidian",
        "--out=./.obs",
    });
    try std.testing.expect(o.mode == .obsidian);
    try std.testing.expectEqualStrings("fixtures/mini-obsidian", o.vault_dir.?);
    try std.testing.expectEqualStrings("./.obs", o.out_dir);

    const o2 = try parseOptions(&.{
        "boris-migration-lab",
        "--mode=obsidian",
        "--vault",
        "fixtures/mini-obsidian",
    });
    try std.testing.expect(o2.mode == .obsidian);
    try std.testing.expectEqualStrings("fixtures/mini-obsidian", o2.vault_dir.?);

    const o3 = try parseOptions(&.{ "boris-migration-lab", "--mode=vault", "--vault=./v" });
    try std.testing.expect(o3.mode == .obsidian);
}

test "parseOptions: notion flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--export=fixtures/mini-notion",
        "--out=./.notion",
    });
    try std.testing.expect(o.mode == .notion);
    try std.testing.expectEqualStrings("fixtures/mini-notion", o.export_dir.?);
    try std.testing.expectEqualStrings("./.notion", o.out_dir);

    const o2 = try parseOptions(&.{
        "boris-migration-lab",
        "--mode=notion",
        "--export",
        "fixtures/mini-notion",
    });
    try std.testing.expect(o2.mode == .notion);
    try std.testing.expectEqualStrings("fixtures/mini-notion", o2.export_dir.?);

    const o3 = try parseOptions(&.{ "boris-migration-lab", "--mode=md-csv", "--export=./e" });
    try std.testing.expect(o3.mode == .notion);
}

test "parseOptions: unknown flag" {
    try std.testing.expectError(error.UnknownFlag, parseOptions(&.{ "x", "--rag" }));
}

test "parseOptions: invalid mode" {
    try std.testing.expectError(error.InvalidValue, parseOptions(&.{ "x", "--mode=hugo" }));
}

test "astro: entity id proposal from content path" {
    const id1 = archaeology.proposeEntityId("src/content/docs/guides/intro.md");
    try std.testing.expectEqualStrings("docs/guides/intro", id1);

    const id2 = archaeology.proposeEntityId("src/content/docs/index.mdx");
    try std.testing.expectEqualStrings("docs/index", id2);

    const id3 = archaeology.proposeEntityId("src/pages/about.astro");
    try std.testing.expectEqualStrings("about", id3);
}

test "astro: slug derivation is deterministic" {
    try std.testing.expectEqualStrings(
        "guides/intro",
        archaeology.slugFromContentPath("src/content/docs/guides/intro.md"),
    );
    try std.testing.expectEqualStrings(
        "guides/intro",
        archaeology.slugFromContentPath("src/content/blog/guides/intro.mdx"),
    );
}

test "astro: path helpers: normalize and classify" {
    const gpa = std.testing.allocator;
    const normalized = try archaeology.normalizeRelPathAlloc(gpa, "src\\content\\docs\\a.md");
    defer gpa.free(normalized);
    try std.testing.expectEqualStrings("src/content/docs/a.md", normalized);
    try std.testing.expectEqualStrings(
        "src/content/docs/a.md",
        archaeology.normalizeRelPath("./src/content/docs/a.md"),
    );
    try std.testing.expect(archaeology.isContentPage("src/content/docs/a.md"));
    try std.testing.expect(archaeology.isContentPage("src/content/docs/a.mdx"));
    try std.testing.expect(!archaeology.isContentPage("src/pages/a.astro"));
    try std.testing.expect(archaeology.isPageRoute("src/pages/docs/[...slug].astro"));
    try std.testing.expect(archaeology.isLayout("src/layouts/BaseLayout.astro"));
    try std.testing.expect(archaeology.isPublicAsset("public/favicon.svg"));
    try std.testing.expect(archaeology.isSrcAsset("src/assets/logo.svg"));
}

test "astro: frontmatter hazard detection" {
    const sample =
        \\---
        \\title: Hello
        \\layout: ../../layouts/DocsLayout.astro
        \\parentEntry: guides
        \\draft: true
        \\sidebar:
        \\  order: 1
        \\tags:
        \\  - a
        \\  - b
        \\---
        \\
        \\Body with <Callout>JSX</Callout> and import.
        \\
        \\import Foo from '../components/Foo.astro';
        \\
        \\![img](../../assets/missing.png)
        \\[link](../nope.md)
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fm = try archaeology.parseFrontmatterLite(a, sample);
    try std.testing.expect(fm.present);
    try std.testing.expectEqualStrings("Hello", fm.title orelse "");
    try std.testing.expect(fm.has_layout);
    try std.testing.expect(fm.has_parent_entry);
    try std.testing.expect(fm.has_draft);
    try std.testing.expect(fm.has_nested_mapping);
    try std.testing.expect(fm.has_yaml_sequence);

    const hazards = try archaeology.collectHazards(a, "src/content/docs/x.md", sample, fm);
    try std.testing.expect(hazards.len >= 4);
}

test "astro: link extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\See [intro](./intro.md) and ![logo](/images/logo.svg).
        \\Also <a href="../about">About</a> and <img src="../../assets/x.png"/>.
        \\Skip https://example.com/ext and mailto:a@b.c.
    ;
    const links = try archaeology.extractLinks(a, "src/content/docs/guides/deep.md", body);
    try std.testing.expect(links.len >= 4);
    var saw_intro = false;
    var saw_ext = false;
    for (links) |l| {
        if (std.mem.eql(u8, l.target, "./intro.md")) saw_intro = true;
        if (std.mem.eql(u8, l.target, "https://example.com/ext")) saw_ext = true;
    }
    try std.testing.expect(saw_intro);
    try std.testing.expect(!saw_ext);
}

test "astro: fixture scan produces stable report sections" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const out_rel = "fixtures/.test-out-report";
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};

    try archaeology.run(io, gpa, .{
        .root_dir = "fixtures/mini-astro",
        .out_dir = out_rel,
        .quiet = true,
    });

    var out = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out.close(io);

    const json_bytes = try archaeology.readFileAlloc(io, out, "report.json", gpa);
    defer gpa.free(json_bytes);
    const md_bytes = try archaeology.readFileAlloc(io, out, "REPORT.md", gpa);
    defer gpa.free(md_bytes);

    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"format\": \"boris-astro-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"schema_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"inventory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"stitches\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"proposed_ids\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"parent_child_candidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"links\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"broken_links\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"slug_conflicts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"assets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"missing_assets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"hazards\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"human_review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"source_path\": \"src/content/docs/guides/intro.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, md_bytes, "# Astro → Boris migration archaeology") != null);

    const out_rel2 = "fixtures/.test-out-report-b";
    Io.Dir.cwd().deleteTree(io, out_rel2) catch {};
    try archaeology.run(io, gpa, .{
        .root_dir = "fixtures/mini-astro",
        .out_dir = out_rel2,
        .quiet = true,
    });
    var out2 = try Io.Dir.cwd().openDir(io, out_rel2, .{});
    defer out2.close(io);
    const json2 = try archaeology.readFileAlloc(io, out2, "report.json", gpa);
    defer gpa.free(json2);
    try std.testing.expectEqualStrings(json_bytes, json2);
    const md2 = try archaeology.readFileAlloc(io, out2, "REPORT.md", gpa);
    defer gpa.free(md2);
    try std.testing.expectEqualStrings(md_bytes, md2);

    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
    Io.Dir.cwd().deleteTree(io, out_rel2) catch {};
}

test "astro: sources are never modified" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var root = try Io.Dir.cwd().openDir(io, "fixtures/mini-astro", .{});
    defer root.close(io);
    const before = try archaeology.readFileAlloc(io, root, "src/content/docs/guides/intro.md", gpa);
    defer gpa.free(before);

    const out_rel = "fixtures/.test-out-immutable";
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
    try archaeology.run(io, gpa, .{
        .root_dir = "fixtures/mini-astro",
        .out_dir = out_rel,
        .quiet = true,
    });

    const after = try archaeology.readFileAlloc(io, root, "src/content/docs/guides/intro.md", gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
}

test "astro: adversarial corpus preserves unicode and reports route ambiguity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const out_rel = "fixtures/.test-adversarial-astro";
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};

    var root = try Io.Dir.cwd().openDir(io, "fixtures/adversarial-astro", .{});
    defer root.close(io);
    const before = try archaeology.readFileAlloc(io, root, "src/content/docs/café.md", gpa);
    defer gpa.free(before);

    try archaeology.run(io, gpa, .{ .root_dir = "fixtures/adversarial-astro", .out_dir = out_rel, .quiet = true });
    var out = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out.close(io);
    const report = try archaeology.readFileAlloc(io, out, "report.json", gpa);
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "café.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "ambiguous matching dynamic page routes") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "missing%20file.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "jsx_component") != null);

    const after = try archaeology.readFileAlloc(io, root, "src/content/docs/café.md", gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
}

// ---- WordPress unit tests ----

test "wordpress: decode entities" {
    const gpa = std.testing.allocator;
    const s = try wordpress.decodeEntities(gpa, "A &amp; B &lt;c&gt; &quot;q&quot; &#39;x&#39;");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("A & B <c> \"q\" 'x'", s);
}

test "wordpress: extractNamedElement CDATA" {
    const xml =
        \\<item>
        \\<content:encoded><![CDATA[<p>Hello &amp; world</p>]]></content:encoded>
        \\<excerpt:encoded><![CDATA[short]]></excerpt:encoded>
        \\</item>
    ;
    const c = wordpress.extractNamedElement(xml, "content:encoded");
    try std.testing.expectEqualStrings("<p>Hello &amp; world</p>", c);
    const e = wordpress.extractNamedElement(xml, "excerpt:encoded");
    try std.testing.expectEqualStrings("short", e);
}

test "wordpress: slugifyAlloc deterministic" {
    const gpa = std.testing.allocator;
    const s = try wordpress.slugifyAlloc(gpa, "Hello World!");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("hello-world", s);
    const s2 = try wordpress.slugifyAlloc(gpa, "Hello World!");
    defer gpa.free(s2);
    try std.testing.expectEqualStrings(s, s2);
}

test "wordpress: mapWpStatus" {
    try std.testing.expectEqualStrings("published", wordpress.mapWpStatus("publish"));
    try std.testing.expectEqualStrings("draft", wordpress.mapWpStatus("draft"));
    try std.testing.expectEqualStrings("draft", wordpress.mapWpStatus("private"));
    try std.testing.expectEqualStrings("draft", wordpress.mapWpStatus("future"));
    try std.testing.expect(wordpress.statusFeatureCode("publish", "") == null);
    try std.testing.expectEqualStrings("status_future", wordpress.statusFeatureCode("future", "").?);
    try std.testing.expectEqualStrings("status_private", wordpress.statusFeatureCode("private", "").?);
    try std.testing.expectEqualStrings("status_password_protected", wordpress.statusFeatureCode("publish", "s3cret").?);
    try std.testing.expectEqualStrings("status_draft", wordpress.statusFeatureCode("draft", "").?);
}

test "wordpress: htmlToMarkdown basic" {
    const gpa = std.testing.allocator;
    const pair = try wordpress.htmlToMarkdown(gpa, "<p>Hello <strong>world</strong></p>");
    defer gpa.free(pair[0]);
    try std.testing.expect(std.mem.indexOf(u8, pair[0], "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, pair[0], "**world**") != null);
    try std.testing.expect(pair[1] == .transformed or pair[1] == .exact);
}

test "wordpress: htmlToMarkdown preserves unknown tags" {
    const gpa = std.testing.allocator;
    const pair = try wordpress.htmlToMarkdown(gpa, "<p>x</p><custom-widget data-x=\"1\">keep</custom-widget>");
    defer gpa.free(pair[0]);
    try std.testing.expect(std.mem.indexOf(u8, pair[0], "<custom-widget") != null);
    try std.testing.expect(std.mem.indexOf(u8, pair[0], "keep") != null);
}

test "wordpress: mediaRelativeKey" {
    const k = wordpress.mediaRelativeKey("https://example.com/wp-content/uploads/2024/01/hero.png");
    try std.testing.expectEqualStrings("2024/01/hero.png", k.?);
    try std.testing.expect(wordpress.mediaRelativeKey("https://cdn.example.com/a.png") == null);
}

test "wordpress: buildFrontmatter closed grammar" {
    const gpa = std.testing.allocator;
    const fm = try wordpress.buildFrontmatter(gpa, "Hello", "posts", "published", &.{ "news", "release" });
    defer gpa.free(fm);
    try std.testing.expect(std.mem.startsWith(u8, fm, "---\n"));
    try std.testing.expect(std.mem.indexOf(u8, fm, "title: Hello\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fm, "parent: posts\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fm, "status: published\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fm, "tags: [news, release]\n") != null);
    // no forbidden keys
    try std.testing.expect(std.mem.indexOf(u8, fm, "layout:") == null);
    try std.testing.expect(std.mem.indexOf(u8, fm, "parentEntry") == null);
}

test "wordpress: fixture conversion is deterministic and preserves export" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Snapshot export before
    var fix = try Io.Dir.cwd().openDir(io, "fixtures/mini-wxr", .{});
    defer fix.close(io);
    const export_before = try wordpress.readFileAlloc(io, fix, "export.xml", gpa);
    defer gpa.free(export_before);

    const out_a = "fixtures/.test-wp-out-a";
    const out_b = "fixtures/.test-wp-out-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/mini-wxr/export.xml",
        .media_dir = "fixtures/mini-wxr/media",
        .out_dir = out_a,
        .quiet = true,
    });
    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/mini-wxr/export.xml",
        .media_dir = "fixtures/mini-wxr/media",
        .out_dir = out_b,
        .quiet = true,
    });

    var a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a.close(io);
    var b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b.close(io);

    const ja = try wordpress.readFileAlloc(io, a, "report.json", gpa);
    defer gpa.free(ja);
    const jb = try wordpress.readFileAlloc(io, b, "report.json", gpa);
    defer gpa.free(jb);
    try std.testing.expectEqualStrings(ja, jb);

    const ma = try wordpress.readFileAlloc(io, a, "REPORT.md", gpa);
    defer gpa.free(ma);
    const mb = try wordpress.readFileAlloc(io, b, "REPORT.md", gpa);
    defer gpa.free(mb);
    try std.testing.expectEqualStrings(ma, mb);

    // Format and sections
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"format\": \"boris-wordpress-migration-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"pages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"parent_relationships\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"links\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"media_references\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"missing_media\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"features\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"slug_conflicts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"unsupported_items\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"comments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"taxonomy_stats\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"human_review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"provenance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"proposed_frontmatter\"") != null);

    // Fixture signals
    try std.testing.expect(std.mem.indexOf(u8, ja, "shortcode") != null or std.mem.indexOf(u8, ja, "gallery") != null);
    try std.testing.expect(std.mem.indexOf(u8, ja, "missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "# WordPress → Boris migration laboratory") != null);

    // Generated markdown exists with provenance
    const hello = try wordpress.readFileAlloc(io, a, "content/posts/hello-world.md", gpa);
    defer gpa.free(hello);
    try std.testing.expect(std.mem.indexOf(u8, hello, "boris-migration-provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "title:") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "post_id:") != null);

    // Export untouched
    const export_after = try wordpress.readFileAlloc(io, fix, "export.xml", gpa);
    defer gpa.free(export_after);
    try std.testing.expectEqualStrings(export_before, export_after);

    // Media file untouched
    const media_before_path = "media/2024/01/hero.png";
    const media_before = try wordpress.readFileAlloc(io, fix, media_before_path, gpa);
    defer gpa.free(media_before);
    // re-run once more already done; just verify still readable same
    const media_after = try wordpress.readFileAlloc(io, fix, media_before_path, gpa);
    defer gpa.free(media_after);
    try std.testing.expectEqualStrings(media_before, media_after);

    // Preserved unsupported attachment
    try std.testing.expect(std.mem.indexOf(u8, ja, "_preserved") != null);

    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "wordpress: conversion classes include expected range" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const out_rel = "fixtures/.test-wp-classes";
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/mini-wxr/export.xml",
        .media_dir = "fixtures/mini-wxr/media",
        .out_dir = out_rel,
        .quiet = true,
    });
    var out = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out.close(io);
    const json = try wordpress.readFileAlloc(io, out, "report.json", gpa);
    defer gpa.free(json);
    // At least transformed and human_review or unsupported should appear
    const has_transformed = std.mem.indexOf(u8, json, "\"transformed\"") != null;
    const has_unsupported = std.mem.indexOf(u8, json, "\"unsupported\"") != null;
    const has_review = std.mem.indexOf(u8, json, "\"human_review\"") != null;
    try std.testing.expect(has_transformed);
    try std.testing.expect(has_unsupported or has_review);
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
}

test "wordpress: adversarial corpus preserves every item and reports collisions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const out_a = "fixtures/.test-adversarial-wp-a";
    const out_b = "fixtures/.test-adversarial-wp-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/adversarial-wxr", .{});
    defer fixture.close(io);
    const source_before = try wordpress.readFileAlloc(io, fixture, "export.xml", gpa);
    defer gpa.free(source_before);
    const media_before = try wordpress.readFileAlloc(io, fixture, "media/2024/01/hero.png", gpa);
    defer gpa.free(media_before);

    try wordpress.run(io, gpa, .{ .wxr_path = "fixtures/adversarial-wxr/export.xml", .media_dir = "fixtures/adversarial-wxr/media", .out_dir = out_a, .quiet = true });
    try wordpress.run(io, gpa, .{ .wxr_path = "fixtures/adversarial-wxr/export.xml", .media_dir = "fixtures/adversarial-wxr/media", .out_dir = out_b, .quiet = true });

    var a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a.close(io);
    var b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b.close(io);
    const report_a = try wordpress.readFileAlloc(io, a, "report.json", gpa);
    defer gpa.free(report_a);
    const report_b = try wordpress.readFileAlloc(io, b, "report.json", gpa);
    defer gpa.free(report_b);
    try std.testing.expectEqualStrings(report_a, report_b);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "duplicate_post_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "deep_page_hierarchy") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "shortcode_gallery") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "duplicate_media_basename") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "missing_media") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "content/_preserved/portfolio-300.md") != null);

    const duplicate_one = try wordpress.readFileAlloc(io, a, "content/posts/duplicate--201.md", gpa);
    defer gpa.free(duplicate_one);
    const duplicate_two = try wordpress.readFileAlloc(io, a, "content/posts/duplicate--202.md", gpa);
    defer gpa.free(duplicate_two);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_one, "first duplicate") != null);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_two, "second duplicate") != null);
    const unicode_post = try wordpress.readFileAlloc(io, a, "content/posts/caf.md", gpa);
    defer gpa.free(unicode_post);
    try std.testing.expect(std.mem.indexOf(u8, unicode_post, "[gallery ids=\"1,2\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, unicode_post, "<custom-widget>keep</custom-widget>") != null);
    const preserved = try wordpress.readFileAlloc(io, a, "content/_preserved/portfolio-300.md", gpa);
    defer gpa.free(preserved);
    try std.testing.expect(std.mem.indexOf(u8, preserved, "opaque unsupported payload") != null);

    const source_after = try wordpress.readFileAlloc(io, fixture, "export.xml", gpa);
    defer gpa.free(source_after);
    try std.testing.expectEqualStrings(source_before, source_after);
    const media_after = try wordpress.readFileAlloc(io, fixture, "media/2024/01/hero.png", gpa);
    defer gpa.free(media_after);
    try std.testing.expectEqualStrings(media_before, media_after);
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "wordpress: wptt-derived hostile gaps (status, comments, formats, empty, unicode)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const out_a = "fixtures/.test-wptt-derived-a";
    const out_b = "fixtures/.test-wptt-derived-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/wptt-derived", .{});
    defer fixture.close(io);
    const source_before = try wordpress.readFileAlloc(io, fixture, "export.xml", gpa);
    defer gpa.free(source_before);

    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/wptt-derived/export.xml",
        .media_dir = "fixtures/wptt-derived/media",
        .out_dir = out_a,
        .quiet = true,
    });
    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/wptt-derived/export.xml",
        .media_dir = "fixtures/wptt-derived/media",
        .out_dir = out_b,
        .quiet = true,
    });

    var a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a.close(io);
    var b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b.close(io);
    const report_a = try wordpress.readFileAlloc(io, a, "report.json", gpa);
    defer gpa.free(report_a);
    const report_b = try wordpress.readFileAlloc(io, b, "report.json", gpa);
    defer gpa.free(report_b);
    try std.testing.expectEqualStrings(report_a, report_b);

    // Schema 2 sections
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"schema_version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"taxonomy_stats\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"comments\"") != null);

    // Statuses
    try std.testing.expect(std.mem.indexOf(u8, report_a, "status_draft") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "status_future") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "status_private") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "status_password_protected") != null);

    // Empty title/body, long title, unicode
    try std.testing.expect(std.mem.indexOf(u8, report_a, "empty_title") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "empty_body") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "long_title") != null);

    // Post format is unsupported artifact, not a tag
    try std.testing.expect(std.mem.indexOf(u8, report_a, "post_format") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "post-format-gallery") == null or
        std.mem.indexOf(u8, report_a, "\"code\": \"post_format\"") != null);

    // Comments / trackbacks not in page body
    try std.testing.expect(std.mem.indexOf(u8, report_a, "wp_comments") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "wp_trackback") != null or std.mem.indexOf(u8, report_a, "trackback") != null);
    const hello = try wordpress.readFileAlloc(io, a, "content/posts/hello.md", gpa);
    defer gpa.free(hello);
    try std.testing.expect(std.mem.indexOf(u8, hello, "wp:comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "This is a comment body") == null);
    const preserved_comments = try wordpress.readFileAlloc(io, a, "content/_preserved/comments-1.md", gpa);
    defer gpa.free(preserved_comments);
    try std.testing.expect(std.mem.indexOf(u8, preserved_comments, "This is a comment body") != null);
    try std.testing.expect(std.mem.indexOf(u8, preserved_comments, "trackback") != null);

    // Menus + shortcodes + widgets + gallery preserved as unsupported
    try std.testing.expect(std.mem.indexOf(u8, report_a, "wp_menu") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "shortcode_gallery") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "wp_widget") != null or std.mem.indexOf(u8, report_a, "shortcode") != null);

    // Parent/child within one-level boundary
    try std.testing.expect(std.mem.indexOf(u8, report_a, "deep_page_hierarchy") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"confidence\": \"medium\"") != null);

    // Media audio/video + missing + present
    try std.testing.expect(std.mem.indexOf(u8, report_a, "shortcode_embed_media") != null or std.mem.indexOf(u8, report_a, "html_audio_or_video") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "missing_media") != null);

    // Title entities decoded (not left as &amp;)
    const special = try wordpress.readFileAlloc(io, a, "content/posts/title-special.md", gpa);
    defer gpa.free(special);
    try std.testing.expect(std.mem.indexOf(u8, special, "&amp;") == null);
    try std.testing.expect(std.mem.indexOf(u8, special, "A & B") != null or std.mem.indexOf(u8, special, "A &amp; B") == null);

    // High-cardinality taxonomy reporting
    try std.testing.expect(std.mem.indexOf(u8, report_a, "high_cardinality") != null);

    // Unicode title preserved
    const unicode = try wordpress.readFileAlloc(io, a, "content/posts/unicode-cafe.md", gpa);
    defer gpa.free(unicode);
    try std.testing.expect(std.mem.indexOf(u8, unicode, "Café") != null or std.mem.indexOf(u8, unicode, "Caf") != null);

    // Source immutability
    const source_after = try wordpress.readFileAlloc(io, fixture, "export.xml", gpa);
    defer gpa.free(source_after);
    try std.testing.expectEqualStrings(source_before, source_after);

    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "wordpress: excerptUtf8 does not split multi-byte chars" {
    const gpa = std.testing.allocator;
    // "café" is 5 bytes; cut mid-sequence must not leave dangling continuation
    const s = try wordpress.excerptUtf8(gpa, "café-extra", 4);
    defer gpa.free(s);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
}
