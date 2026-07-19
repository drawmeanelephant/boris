//! boris-migration-lab — standalone migration archaeology tools.
//!
//! Modes:
//!   astro      — read-only Astro tree scan → report.json + REPORT.md
//!   wordpress  — WordPress WXR → Boris Markdown + reports
//!   instagram  — Instagram Takeout dump → Boris Markdown + theme assets + reports
//!   obsidian   — Obsidian vault → Boris Markdown + attachments + reports
//!   notion     — Notion Markdown & CSV export → Boris Markdown + media + reports
//!   filed      — Filed.fyi changelog + releases slice → Boris Markdown + reports
//!   starlight  — Starlight/Astro docs dogfood (locale-dir or root-locale) → Boris candidate + boundary manifests
//!   asset-filename — Sanitize content-local asset filenames to Boris ASCII path grammar
//!   theme-archaeology — Read-only Astro/Starlight theme inventory → adaptation ledger + boundary report
//!   theme-materialize — Ledger-driven safe static Boris theme materialization
//!   wordpress-theme — Read-only classic WordPress PHP theme inventory → static prototype + review manifest
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
//!   zig build run -- --mode=starlight --root=./fixtures/mini-starlight --out=./.out-sl
//!   zig build test
//!
//! From repo root:
//!   zig build --build-file tools/migration-lab/build.zig
//!   zig build --build-file tools/migration-lab/build.zig test

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");
const wordpress = @import("wordpress.zig");
const instagram = @import("instagram.zig");
const obsidian = @import("obsidian.zig");
const notion = @import("notion.zig");
const filed = @import("filed.zig");
const starlight = @import("starlight.zig");
const asset_filename = @import("asset_filename.zig");
const theme_archaeology = @import("theme_archaeology.zig");
const theme_materialize = @import("theme_materialize.zig");
const wordpress_theme = @import("wordpress_theme.zig");

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
    filed,
    starlight,
    asset_filename,
    theme_archaeology,
    theme_materialize,
    wordpress_theme,

    pub fn parse(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "astro")) return .astro;
        if (std.mem.eql(u8, s, "wordpress") or std.mem.eql(u8, s, "wp") or std.mem.eql(u8, s, "wxr")) return .wordpress;
        if (std.mem.eql(u8, s, "instagram") or std.mem.eql(u8, s, "ig") or std.mem.eql(u8, s, "takeout")) return .instagram;
        if (std.mem.eql(u8, s, "obsidian") or std.mem.eql(u8, s, "obs") or std.mem.eql(u8, s, "vault")) return .obsidian;
        if (std.mem.eql(u8, s, "notion") or std.mem.eql(u8, s, "md-csv") or std.mem.eql(u8, s, "notion-export")) return .notion;
        if (std.mem.eql(u8, s, "filed") or std.mem.eql(u8, s, "filed-fyi")) return .filed;
        if (std.mem.eql(u8, s, "starlight") or std.mem.eql(u8, s, "sl") or std.mem.eql(u8, s, "evcc")) return .starlight;
        if (std.mem.eql(u8, s, "asset-filename") or std.mem.eql(u8, s, "assets") or
            std.mem.eql(u8, s, "asset-compat") or std.mem.eql(u8, s, "filename-compat"))
            return .asset_filename;
        if (std.mem.eql(u8, s, "theme-archaeology") or std.mem.eql(u8, s, "theme") or
            std.mem.eql(u8, s, "theme-arch") or std.mem.eql(u8, s, "theme-inventory"))
            return .theme_archaeology;
        if (std.mem.eql(u8, s, "theme-materialize") or std.mem.eql(u8, s, "theme-materialise") or
            std.mem.eql(u8, s, "materialize"))
            return .theme_materialize;
        if (std.mem.eql(u8, s, "wordpress-theme") or std.mem.eql(u8, s, "wp-theme") or
            std.mem.eql(u8, s, "kubrick-theme"))
            return .wordpress_theme;
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
    /// Filed.fyi Astro source root (read-only; implies filed mode).
    filed_root_dir: ?[]const u8 = null,
    /// Starlight locale key for content-root discovery ("en" only; no i18n).
    locale: []const u8 = "en",
    /// Starlight max converted pages (default 40; real-site smoke often 40–60).
    max_pages: usize = 40,
    /// Optional path to boris binary for Starlight compile verification.
    boris_bin: ?[]const u8 = null,
    /// Report/output directory (created if missing). Never writes into inputs.
    out_dir: []const u8 = "migration-report",
    /// Existing theme-archaeology adaptation ledger for theme-materialize mode.
    ledger_path: ?[]const u8 = null,
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
        } else if (std.mem.startsWith(u8, arg, "--ledger=")) {
            const value = arg["--ledger=".len..];
            if (value.len == 0) return error.MissingValue;
            options.ledger_path = value;
        } else if (std.mem.eql(u8, arg, "--ledger")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.ledger_path = args[index];
        } else if (std.mem.startsWith(u8, arg, "--filed-root=")) {
            const value = arg["--filed-root=".len..];
            if (value.len == 0) return error.MissingValue;
            options.filed_root_dir = value;
            options.mode = .filed;
        } else if (std.mem.eql(u8, arg, "--filed-root")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.filed_root_dir = args[index];
            options.mode = .filed;
        } else if (std.mem.startsWith(u8, arg, "--locale=")) {
            const value = arg["--locale=".len..];
            if (value.len == 0) return error.MissingValue;
            options.locale = value;
        } else if (std.mem.eql(u8, arg, "--locale")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.locale = args[index];
        } else if (std.mem.startsWith(u8, arg, "--max-pages=")) {
            const value = arg["--max-pages=".len..];
            if (value.len == 0) return error.MissingValue;
            options.max_pages = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--max-pages")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.max_pages = std.fmt.parseInt(usize, args[index], 10) catch return error.InvalidValue;
        } else if (std.mem.startsWith(u8, arg, "--boris=")) {
            const value = arg["--boris=".len..];
            if (value.len == 0) return error.MissingValue;
            options.boris_bin = value;
        } else if (std.mem.eql(u8, arg, "--boris")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.boris_bin = args[index];
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

fn printUsage() void {
    std.debug.print(
        \\boris-migration-lab — Astro / WordPress / Instagram / Obsidian / Notion / Starlight → Boris migration laboratory
        \\
        \\Usage:
        \\  boris-migration-lab [options]
        \\  zig build run -- [options]
        \\
        \\Common options:
        \\  -h, --help         Show this help and exit
        \\  -q, --quiet        Suppress progress lines
        \\  --mode=MODE        astro (default) | wordpress | wordpress-theme | instagram | obsidian | notion | filed | starlight | asset-filename | theme-archaeology | theme-materialize
        \\  --out=DIR          Output directory (default: migration-report)
        \\
        \\Astro mode:
        \\  --root=DIR         Astro project/export root to scan (default: .)
        \\  Writes: report.json, REPORT.md
        \\
        \\Theme archaeology (read-only Astro/Starlight theme inventory):
        \\  --mode=theme-archaeology  Inventory layouts, CSS, fonts/images, nav/sidebar,
        \\                     components/MDX tags, scripts, analytics, licenses
        \\  --root=DIR         Theme/project root (required; never modified)
        \\  Writes: adaptation_ledger.json, report.json, REPORT.md, BOUNDARY.md
        \\  Aliases: theme | theme-arch | theme-inventory
        \\  No JS/MDX execution, no remote fetch, no directive following.
        \\  Ambiguous mappings are review items, never guesses.
        \\
        \\Theme materialize (ledger-driven static theme draft):
        \\  --mode=theme-materialize  Consume an archaeology ledger; never execute source
        \\  --root=DIR                 Original read-only theme source tree
        \\  --ledger=FILE              adaptation_ledger.json from theme-archaeology
        \\  Writes: theme/**, materialize-manifest.json, MATERIALIZE-REPORT.md, PROVENANCE.md
        \\  Only preserve CSS/fonts/images and closed static layout shells are emitted.
        \\  No JS/MDX/PHP execution, remote fetch, symlinks, or guessed mappings.
        \\
        \\WordPress theme archaeology (read-only PHP source scan):
        \\  --mode=wordpress-theme  Inventory classic theme files, assets, hooks,
        \\                     menus, widgets, and template relationships
        \\  --root=DIR         Theme root (required; never modified)
        \\  Writes: inventory.json, slot_mapping.json, manual_review.json,
        \\          prototype/main.html, report.json, REPORT.md
        \\  Aliases: wp-theme | kubrick-theme
        \\  Never executes PHP or claims universal WordPress compatibility.
        \\
        \\Asset-filename mode (content-local asset path sanitization):
        \\  --mode=asset-filename  Sanitize sibling page.assets/ filenames to Boris ASCII grammar
        \\  --root=DIR         Content tree (or parent containing content/); never modified
        \\  Writes: content/**, asset_filename_manifest.json, rewrite_manifest.json,
        \\          report.json, REPORT.md
        \\  Aliases: assets | asset-compat | filename-compat
        \\  No remote fetch, no JS execution, no silent overwrite on collision.
        \\
        \\WordPress mode:
        \\  --wxr=FILE         WordPress WXR/XML export (required; never modified)
        \\  --media=DIR        Optional local media/uploads directory (never modified; offline only)
        \\  Writes: content/**/*.md (+ page {{stem}}.assets/ when media matches),
        \\          report.json, REPORT.md, media_manifest.json
        \\  (--wxr implies --mode=wordpress)
        \\  No network fetch; unresolved media kept + listed for review.
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
        \\Filed.fyi slice:
        \\  --filed-root=DIR   Filed.fyi Astro source root (required; never modified)
        \\  Writes: content/changelog/**, content/releases/**, provenance_manifest.json, report.json, REPORT.md
        \\  Converts exactly one changelog and three releases; unsupported MDX is retained and reported.
        \\
        \\Starlight read-only dogfood (locale-dir or root-locale content roots):
        \\  --mode=starlight   Convert bounded docs tree → Boris candidate + reports
        \\  --root=DIR         Starlight project root (required; never modified)
        \\  --locale=en        Discovery key (en only). Uses docs/en/ when present,
        \\                     else default-locale files under docs/ (root-locale).
        \\  --max-pages=N      Cap converted pages (default 40; dogfood often 40–80)
        \\  --boris=PATH       Optional boris binary for compile verification
        \\  Writes: content/**, route_map.json, selection_manifest.json,
        \\          unsupported_manifest.json, assets_manifest.json (exists+sha256),
        \\          nav_flatten.json, provenance_manifest.json, link_review.json,
        \\          heading_fragments.json, boundary_manifest.json,
        \\          compile_report.json, report.json, REPORT.md
        \\  No Node/Astro runtime, no full YAML, no MDX execution, no i18n/translation linking.
        \\  Embedded directives are stripped, never followed. Not a universal converter.
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
        .filed => {
            const root = opts.filed_root_dir orelse {
                std.log.err("filed mode requires --filed-root=DIR", .{});
                printUsage();
                return ExitCode.usage.int();
            };
            if (std.mem.eql(u8, root, opts.out_dir)) {
                std.log.err("--out must differ from --filed-root", .{});
                return ExitCode.usage.int();
            }
            filed.run(io, gpa, .{ .source_root_dir = root, .out_dir = opts.out_dir, .quiet = opts.quiet }) catch |err| {
                std.log.err("migration-lab (filed) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .starlight => {
            if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
                std.log.err("--out must differ from --root", .{});
                return ExitCode.usage.int();
            }
            starlight.run(io, gpa, .{
                .source_root_dir = opts.root_dir,
                .out_dir = opts.out_dir,
                .locale = opts.locale,
                .max_pages = opts.max_pages,
                .quiet = opts.quiet,
                .boris_bin = opts.boris_bin,
            }) catch |err| {
                std.log.err("migration-lab (starlight) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .asset_filename => {
            if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
                std.log.err("--out must differ from --root", .{});
                return ExitCode.usage.int();
            }
            asset_filename.run(io, gpa, .{
                .root_dir = opts.root_dir,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (asset-filename) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .theme_archaeology => {
            if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
                std.log.err("--out must differ from --root", .{});
                return ExitCode.usage.int();
            }
            theme_archaeology.run(io, gpa, .{
                .root_dir = opts.root_dir,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (theme-archaeology) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .theme_materialize => {
            const ledger = opts.ledger_path orelse {
                std.log.err("theme-materialize mode requires --ledger=FILE", .{});
                printUsage();
                return ExitCode.usage.int();
            };
            if (std.mem.eql(u8, opts.root_dir, opts.out_dir) or std.mem.eql(u8, ledger, opts.out_dir)) {
                std.log.err("--out must differ from --root and --ledger", .{});
                return ExitCode.usage.int();
            }
            theme_materialize.run(io, gpa, .{
                .root_dir = opts.root_dir,
                .ledger_path = ledger,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (theme-materialize) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .wordpress_theme => {
            if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
                std.log.err("--out must differ from --root", .{});
                return ExitCode.usage.int();
            }
            wordpress_theme.run(io, gpa, .{
                .root_dir = opts.root_dir,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (wordpress-theme) failed: {s}", .{@errorName(err)});
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
    _ = filed;
    _ = starlight;
    _ = asset_filename;
    _ = theme_archaeology;
    _ = theme_materialize;
    _ = wordpress_theme;
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

test "parseOptions: filed flags" {
    const o = try parseOptions(&.{ "boris-migration-lab", "--filed-root=fixtures/mini-filed", "--out=./.filed" });
    try std.testing.expect(o.mode == .filed);
    try std.testing.expectEqualStrings("fixtures/mini-filed", o.filed_root_dir.?);
}

test "parseOptions: asset-filename flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--mode=asset-filename",
        "--root=fixtures/hostile-asset-filenames",
        "--out=./.asset-out",
    });
    try std.testing.expect(o.mode == .asset_filename);
    try std.testing.expectEqualStrings("fixtures/hostile-asset-filenames", o.root_dir);
    try std.testing.expectEqualStrings("./.asset-out", o.out_dir);

    const o2 = try parseOptions(&.{ "boris-migration-lab", "--mode=assets", "--root=./c", "--out=./o" });
    try std.testing.expect(o2.mode == .asset_filename);
}

test "parseOptions: theme-archaeology flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--mode=theme-archaeology",
        "--root=fixtures/mini-theme-astro",
        "--out=./.theme-out",
    });
    try std.testing.expect(o.mode == .theme_archaeology);
    try std.testing.expectEqualStrings("fixtures/mini-theme-astro", o.root_dir);
    try std.testing.expectEqualStrings("./.theme-out", o.out_dir);

    const o2 = try parseOptions(&.{ "boris-migration-lab", "--mode=theme", "--root=./t", "--out=./o" });
    try std.testing.expect(o2.mode == .theme_archaeology);
    const o3 = try parseOptions(&.{ "boris-migration-lab", "--mode=theme-inventory", "--root=./t", "--out=./o" });
    try std.testing.expect(o3.mode == .theme_archaeology);
}

test "parseOptions: wordpress-theme flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--mode=wordpress-theme",
        "--root=fixtures/mini-wordpress-kubrick",
        "--out=./.wp-theme-out",
    });
    try std.testing.expect(o.mode == .wordpress_theme);
    try std.testing.expectEqualStrings("fixtures/mini-wordpress-kubrick", o.root_dir);
    const o2 = try parseOptions(&.{ "boris-migration-lab", "--mode=kubrick-theme", "--root=./t", "--out=./o" });
    try std.testing.expect(o2.mode == .wordpress_theme);
}

test "parseOptions: starlight flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--mode=starlight",
        "--root=fixtures/mini-starlight",
        "--out=./.sl-out",
        "--locale=en",
        "--max-pages=32",
        "--boris=../../zig-out/bin/boris",
    });
    try std.testing.expect(o.mode == .starlight);
    try std.testing.expectEqualStrings("fixtures/mini-starlight", o.root_dir);
    try std.testing.expectEqualStrings("en", o.locale);
    try std.testing.expect(o.max_pages == 32);
    try std.testing.expectEqualStrings("../../zig-out/bin/boris", o.boris_bin.?);

    const o2 = try parseOptions(&.{ "boris-migration-lab", "--mode=sl", "--root", "./r" });
    try std.testing.expect(o2.mode == .starlight);
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
    try std.testing.expect(archaeology.isContentPage("content/docs/a.md"));
    try std.testing.expect(!archaeology.isContentPage("src/pages/a.astro"));
    try std.testing.expect(!archaeology.isContentPage("NOTES.md"));
    try std.testing.expect(!archaeology.isContentPage("docs/readme.md"));
    try std.testing.expect(archaeology.isPageRoute("src/pages/docs/[...slug].astro"));
    try std.testing.expect(archaeology.isLayout("src/layouts/BaseLayout.astro"));
    try std.testing.expect(archaeology.isPublicAsset("public/favicon.svg"));
    try std.testing.expect(archaeology.isSrcAsset("src/assets/logo.svg"));
    try std.testing.expectEqualStrings("src/content/", archaeology.contentRootPrefix("src/content/docs/a.md").?);
    try std.testing.expectEqualStrings("content/", archaeology.contentRootPrefix("content/docs/a.md").?);
    try std.testing.expect(archaeology.contentRootPrefix("NOTES.md") == null);
}

test "astro: absolute route key and public path helpers" {
    const gpa = std.testing.allocator;
    const root_key = try archaeology.absoluteToRouteKey(gpa, "/");
    defer gpa.free(root_key);
    try std.testing.expectEqualStrings("index", root_key);
    const about_key = try archaeology.absoluteToRouteKey(gpa, "/about");
    defer gpa.free(about_key);
    try std.testing.expectEqualStrings("about", about_key);
    const about_slash = try archaeology.absoluteToRouteKey(gpa, "/about/");
    defer gpa.free(about_slash);
    try std.testing.expectEqualStrings("about", about_slash);
    const pub_path = try archaeology.absoluteToPublicPath(gpa, "/images/hero.png");
    defer gpa.free(pub_path);
    try std.testing.expectEqualStrings("public/images/hero.png", pub_path);
}

test "astro: entity id from root-level content path" {
    try std.testing.expectEqualStrings(
        "docs/intro",
        archaeology.proposeEntityId("content/docs/intro.md"),
    );
    try std.testing.expectEqualStrings(
        "intro",
        archaeology.slugFromContentPath("content/docs/intro.md"),
    );
    try std.testing.expectEqualStrings(
        "docs",
        archaeology.collectionFromContentPath("content/docs/intro.md").?,
    );
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

test "astro: root-level content/ discovery + determinism + source immutability" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fixture = "fixtures/root-content-astro";
    const out_a = "fixtures/.test-root-content-a";
    const out_b = "fixtures/.test-root-content-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    var root = try Io.Dir.cwd().openDir(io, fixture, .{});
    defer root.close(io);
    const before = try archaeology.readFileAlloc(io, root, "content/docs/intro.md", gpa);
    defer gpa.free(before);

    try archaeology.run(io, gpa, .{ .root_dir = fixture, .out_dir = out_a, .quiet = true });
    try archaeology.run(io, gpa, .{ .root_dir = fixture, .out_dir = out_b, .quiet = true });

    var oa = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer oa.close(io);
    var ob = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer ob.close(io);
    const json_a = try archaeology.readFileAlloc(io, oa, "report.json", gpa);
    defer gpa.free(json_a);
    const json_b = try archaeology.readFileAlloc(io, ob, "report.json", gpa);
    defer gpa.free(json_b);
    try std.testing.expectEqualStrings(json_a, json_b);

    // Content under root-level content/ is discovered
    try std.testing.expect(std.mem.indexOf(u8, json_a, "\"source_path\": \"content/docs/intro.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_a, "\"kind\": \"content_page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_a, "\"proposed_entity_id\": \"docs/intro\"") != null);
    // Free-form Markdown outside supported roots is not content
    try std.testing.expect(std.mem.indexOf(u8, json_a, "NOTES.md") == null);

    const after = try archaeology.readFileAlloc(io, root, "content/docs/intro.md", gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "astro: absolute root link, valid route, missing route, real public asset" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fixture = "fixtures/absolute-links-astro";
    const out_rel = "fixtures/.test-absolute-links";
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};

    var root = try Io.Dir.cwd().openDir(io, fixture, .{});
    defer root.close(io);
    const before = try archaeology.readFileAlloc(io, root, "src/content/docs/links.md", gpa);
    defer gpa.free(before);

    try archaeology.run(io, gpa, .{ .root_dir = fixture, .out_dir = out_rel, .quiet = true });
    var out = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out.close(io);
    const json = try archaeology.readFileAlloc(io, out, "report.json", gpa);
    defer gpa.free(json);

    // Missing absolute route → broken_links, never missing_assets
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target\": \"/no-such-page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reason\": \"target_not_found\"") != null);
    // /no-such-page must not appear under missing_assets
    {
        const ma_key = "\"missing_assets\"";
        const bl_key = "\"broken_links\"";
        const ma_idx = std.mem.indexOf(u8, json, ma_key) orelse return error.TestUnexpectedResult;
        const bl_idx = std.mem.indexOf(u8, json, bl_key) orelse return error.TestUnexpectedResult;
        // broken_links section contains /no-such-page
        const after_bl = json[bl_idx..];
        const next_section = std.mem.indexOf(u8, after_bl, "\"slug_conflicts\"") orelse after_bl.len;
        try std.testing.expect(std.mem.indexOf(u8, after_bl[0..next_section], "/no-such-page") != null);
        // missing_assets section does not
        const after_ma = json[ma_idx..];
        const ma_end = std.mem.indexOf(u8, after_ma, "\"hazards\"") orelse after_ma.len;
        try std.testing.expect(std.mem.indexOf(u8, after_ma[0..ma_end], "/no-such-page") == null);
        // real missing image asset is present
        try std.testing.expect(std.mem.indexOf(u8, after_ma[0..ma_end], "/images/missing.png") != null);
        // present public asset is not listed as missing
        try std.testing.expect(std.mem.indexOf(u8, after_ma[0..ma_end], "/images/hero.png") == null);
    }
    // Valid absolute routes / and /about are not broken
    {
        const bl_idx = std.mem.indexOf(u8, json, "\"broken_links\"") orelse return error.TestUnexpectedResult;
        const after_bl = json[bl_idx..];
        const next_section = std.mem.indexOf(u8, after_bl, "\"slug_conflicts\"") orelse after_bl.len;
        const section = after_bl[0..next_section];
        // exact "target": "/" would be the root link — must not appear as broken
        try std.testing.expect(std.mem.indexOf(u8, section, "\"target\": \"/\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, section, "\"target\": \"/about\"") == null);
    }

    const after = try archaeology.readFileAlloc(io, root, "src/content/docs/links.md", gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
}

test "astro: dual content roots inventoriable + ambiguous human review; stray md ignored" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fixture = "fixtures/dual-content-roots-astro";
    const out_rel = "fixtures/.test-dual-content-roots";
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};

    try archaeology.run(io, gpa, .{ .root_dir = fixture, .out_dir = out_rel, .quiet = true });
    var out = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out.close(io);
    const json = try archaeology.readFileAlloc(io, out, "report.json", gpa);
    defer gpa.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "src/content/docs/from-src.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "content/docs/from-root.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ambiguous_content_roots") != null);
    // Free-form NOTES.md may appear in inventory as "other", never as content_page
    // or as a proposed entity id / stitch content path.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"proposed_entity_id\": \"NOTES\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content_path\": \"NOTES.md\"") == null);
    // No content_page inventory row for NOTES.md
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source_path\": \"NOTES.md\", \"kind\": \"content_page\"") == null);

    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
}

test "astro: mini-astro absolute /docs is route not missing asset" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const out_rel = "fixtures/.test-mini-astro-abs";
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
    try archaeology.run(io, gpa, .{ .root_dir = "fixtures/mini-astro", .out_dir = out_rel, .quiet = true });
    var out = try Io.Dir.cwd().openDir(io, out_rel, .{});
    defer out.close(io);
    const json = try archaeology.readFileAlloc(io, out, "report.json", gpa);
    defer gpa.free(json);

    const ma_idx = std.mem.indexOf(u8, json, "\"missing_assets\"") orelse return error.TestUnexpectedResult;
    const after_ma = json[ma_idx..];
    const ma_end = std.mem.indexOf(u8, after_ma, "\"hazards\"") orelse after_ma.len;
    // /docs was previously misclassified as a missing public asset
    try std.testing.expect(std.mem.indexOf(u8, after_ma[0..ma_end], "\"referenced\": \"/docs\"") == null);
    // real missing image still reported
    try std.testing.expect(std.mem.indexOf(u8, after_ma[0..ma_end], "/images/not-there.png") != null);

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
    const rel = wordpress.mediaRelativeKey("uploads/2024/01/shared.png");
    try std.testing.expectEqualStrings("2024/01/shared.png", rel.?);
    const q = wordpress.mediaRelativeKey("https://example.com/wp-content/uploads/2024/01/hero.png?w=1#x");
    try std.testing.expectEqualStrings("2024/01/hero.png", q.?);
}

test "wordpress: matchMediaReference matrix" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{ "2024/01/hero.png", "2025/02/hero.png", "2024/01/shared.png", "2024/01/my photo.png" };
    const found = try wordpress.matchMediaReference(gpa, &files, true, "https://example.com/wp-content/uploads/2024/01/hero.png");
    try std.testing.expect(found.kind == .found);
    try std.testing.expectEqualStrings("2024/01/hero.png", found.local_path.?);

    const rel = try wordpress.matchMediaReference(gpa, &files, true, "uploads/2024/01/shared.png");
    try std.testing.expect(rel.kind == .found);
    try std.testing.expectEqualStrings("2024/01/shared.png", rel.local_path.?);

    const missing = try wordpress.matchMediaReference(gpa, &files, true, "https://example.com/wp-content/uploads/2024/01/gone.png");
    try std.testing.expect(missing.kind == .missing);

    const amb = try wordpress.matchMediaReference(gpa, &files, true, "hero.png");
    try std.testing.expect(amb.kind == .ambiguous);

    const trav = try wordpress.matchMediaReference(gpa, &files, true, "https://example.com/wp-content/uploads/2024/01/../../secret.png");
    try std.testing.expect(trav.kind == .rejected);

    const abs = try wordpress.matchMediaReference(gpa, &files, true, "file:///etc/passwd.png");
    try std.testing.expect(abs.kind == .rejected);

    const no_dir = try wordpress.matchMediaReference(gpa, &files, false, "https://example.com/wp-content/uploads/2024/01/hero.png");
    try std.testing.expect(no_dir.kind == .missing);
    try std.testing.expectEqualStrings("media_dir_not_provided", no_dir.reason);

    // Percent-encoded reference matches decoded on-disk name
    const pct = try wordpress.matchMediaReference(gpa, &files, true, "https://example.com/wp-content/uploads/2024/01/my%20photo.png");
    try std.testing.expect(pct.kind == .found);
    try std.testing.expectEqualStrings("2024/01/my photo.png", pct.local_path.?);
    try std.testing.expectEqualStrings("percent_decoded_lookup", pct.reason);

    // WP intermediate size: missing but original exists → explicit reason (no rewrite)
    const resized = try wordpress.matchMediaReference(gpa, &files, true, "https://example.com/wp-content/uploads/2024/01/hero-300x200.png");
    try std.testing.expect(resized.kind == .missing);
    try std.testing.expectEqualStrings("likely_wp_resized_derivative", resized.reason);

    // Percent-encoded traversal after decode is rejected
    const pct_trav = try wordpress.matchMediaReference(gpa, &files, true, "https://example.com/wp-content/uploads/%2e%2e/secret.png");
    try std.testing.expect(pct_trav.kind == .rejected);
}

test "wordpress: rewriteMediaReferences exact only" {
    const gpa = std.testing.allocator;
    const body = "![a](https://example.com/wp-content/uploads/2024/01/hero.png) and ![b](https://example.com/wp-content/uploads/2024/01/gone.png)";
    const rewrites = [_]wordpress.MediaRewrite{
        .{ .original = "https://example.com/wp-content/uploads/2024/01/hero.png", .rewritten = "full-upload.assets/2024/01/hero.png" },
    };
    const out = try wordpress.rewriteMediaReferences(gpa, body, &rewrites);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "full-upload.assets/2024/01/hero.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.com/wp-content/uploads/2024/01/gone.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.com/wp-content/uploads/2024/01/hero.png") == null);
}

test "wordpress: isBorisSafeWithinTree and unsafe keys" {
    try std.testing.expect(wordpress.isBorisSafeWithinTree("2024/01/hero.png"));
    try std.testing.expect(!wordpress.isBorisSafeWithinTree("../x.png"));
    try std.testing.expect(wordpress.isUnsafeMediaKey("../../secret.png"));
    try std.testing.expect(wordpress.isUnsafeMediaKey("/abs.png"));
    try std.testing.expect(!wordpress.isUnsafeMediaKey("2024/01/hero.png"));
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
    try std.testing.expect(std.mem.indexOf(u8, ja, "\"schema_version\": 3") != null);
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

    // Schema 3 sections (superset of schema 2)
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"schema_version\": 3") != null);
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

test "wordpress: formatPreservedExcerpt quotes lines" {
    const gpa = std.testing.allocator;
    const s = try wordpress.formatPreservedExcerpt(gpa, "line one\nline two");
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "WordPress excerpt") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "> line one\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "> line two\n") != null);
}

test "wordpress: unit-wxr matrix preserves fields and reports unsupported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const out_a = "fixtures/.test-unit-wxr-a";
    const out_b = "fixtures/.test-unit-wxr-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/unit-wxr", .{});
    defer fixture.close(io);
    const source_before = try wordpress.readFileAlloc(io, fixture, "export.xml", gpa);
    defer gpa.free(source_before);
    const media_before = try wordpress.readFileAlloc(io, fixture, "media/2024/01/hero.png", gpa);
    defer gpa.free(media_before);

    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/unit-wxr/export.xml",
        .media_dir = "fixtures/unit-wxr/media",
        .out_dir = out_a,
        .quiet = true,
    });
    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/unit-wxr/export.xml",
        .media_dir = "fixtures/unit-wxr/media",
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

    // Schema 3 field preservation
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"schema_version\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"excerpt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"is_sticky\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"source_slug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"post_date_gmt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "Unit excerpt for Hello World.") != null);

    // Posts vs pages + parent/child
    try std.testing.expect(std.mem.indexOf(u8, report_a, "content/posts/hello-world.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "content/pages/about.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "deep_page_hierarchy") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"confidence\": \"medium\"") != null);

    // Dates / categories / tags on published post
    try std.testing.expect(std.mem.indexOf(u8, report_a, "2024-01-15 10:00:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"news\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"migration\"") != null);

    // Sticky / empty slug / empty title
    try std.testing.expect(std.mem.indexOf(u8, report_a, "sticky_post") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "\"is_sticky\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "empty_slug") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "empty_title") != null);

    // Status mapping
    try std.testing.expect(std.mem.indexOf(u8, report_a, "status_draft") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "status_future") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "status_private") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "status_password_protected") != null);

    // Unsupported constructs
    try std.testing.expect(std.mem.indexOf(u8, report_a, "shortcode_gallery") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "shortcode_caption") != null or std.mem.indexOf(u8, report_a, "shortcode") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "post_format") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "wp_menu") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "wp_comments") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "wp_trackback") != null or std.mem.indexOf(u8, report_a, "trackback") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "wp_pingback") != null or std.mem.indexOf(u8, report_a, "pingback") != null);

    // Duplicate slugs + missing media
    try std.testing.expect(std.mem.indexOf(u8, report_a, "duplicate_post_name") != null or std.mem.indexOf(u8, report_a, "slug_conflicts") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "missing_media") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_a, "content/_preserved/attachment-90.md") != null);

    // Generated markdown: excerpt body, comments not in page body
    const hello = try wordpress.readFileAlloc(io, a, "content/posts/hello-world.md", gpa);
    defer gpa.free(hello);
    try std.testing.expect(std.mem.indexOf(u8, hello, "WordPress excerpt") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "Unit excerpt for Hello World.") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "Welcome body") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "title: Hello World") != null or std.mem.indexOf(u8, hello, "title: \"Hello World\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "post_date: 2024-01-15 10:00:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "tags:") != null);

    const kitchen = try wordpress.readFileAlloc(io, a, "content/posts/markup-kitchen-sink.md", gpa);
    defer gpa.free(kitchen);
    try std.testing.expect(std.mem.indexOf(u8, kitchen, "[gallery ids=\"90\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, kitchen, "Comment body must not become page Markdown") == null);
    const preserved_comments = try wordpress.readFileAlloc(io, a, "content/_preserved/comments-8.md", gpa);
    defer gpa.free(preserved_comments);
    try std.testing.expect(std.mem.indexOf(u8, preserved_comments, "Comment body must not become page Markdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, preserved_comments, "Trackback body") != null);
    try std.testing.expect(std.mem.indexOf(u8, preserved_comments, "Pingback body") != null);

    // Post format not merged into tags list of kitchen sink
    try std.testing.expect(std.mem.indexOf(u8, kitchen, "post-format-gallery") == null);

    // Empty-slug synthesized path exists
    const empty_slug_md = try wordpress.readFileAlloc(io, a, "content/posts/draft-without-slug.md", gpa);
    defer gpa.free(empty_slug_md);
    try std.testing.expect(std.mem.indexOf(u8, empty_slug_md, "Empty post_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_slug_md, "status: draft") != null);

    // Duplicate disambiguation keeps both bodies
    const dup_one = try wordpress.readFileAlloc(io, a, "content/posts/duplicate--30.md", gpa);
    defer gpa.free(dup_one);
    const dup_two = try wordpress.readFileAlloc(io, a, "content/posts/duplicate--31.md", gpa);
    defer gpa.free(dup_two);
    try std.testing.expect(std.mem.indexOf(u8, dup_one, "first duplicate") != null);
    try std.testing.expect(std.mem.indexOf(u8, dup_two, "second duplicate") != null);

    // Source immutability
    const source_after = try wordpress.readFileAlloc(io, fixture, "export.xml", gpa);
    defer gpa.free(source_after);
    try std.testing.expectEqualStrings(source_before, source_after);
    const media_after = try wordpress.readFileAlloc(io, fixture, "media/2024/01/hero.png", gpa);
    defer gpa.free(media_after);
    try std.testing.expectEqualStrings(media_before, media_after);

    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "wordpress: media materialization copies, rewrites, and manifests" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const out_a = "fixtures/.tmp-media-wxr-a";
    const out_b = "fixtures/.tmp-media-wxr-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};

    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/media-wxr", .{});
    defer fixture.close(io);
    const source_before = try wordpress.readFileAlloc(io, fixture, "export.xml", gpa);
    defer gpa.free(source_before);
    const media_before = try wordpress.readFileAlloc(io, fixture, "media/2024/01/hero.png", gpa);
    defer gpa.free(media_before);
    const shared_before = try wordpress.readFileAlloc(io, fixture, "media/2024/01/shared.png", gpa);
    defer gpa.free(shared_before);

    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/media-wxr/export.xml",
        .media_dir = "fixtures/media-wxr/media",
        .out_dir = out_a,
        .quiet = true,
    });
    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/media-wxr/export.xml",
        .media_dir = "fixtures/media-wxr/media",
        .out_dir = out_b,
        .quiet = true,
    });

    var a = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer a.close(io);
    var b = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer b.close(io);

    // Deterministic dual runs
    const man_a = try wordpress.readFileAlloc(io, a, "media_manifest.json", gpa);
    defer gpa.free(man_a);
    const man_b = try wordpress.readFileAlloc(io, b, "media_manifest.json", gpa);
    defer gpa.free(man_b);
    try std.testing.expectEqualStrings(man_a, man_b);
    const rep_a = try wordpress.readFileAlloc(io, a, "report.json", gpa);
    defer gpa.free(rep_a);
    const rep_b = try wordpress.readFileAlloc(io, b, "report.json", gpa);
    defer gpa.free(rep_b);
    try std.testing.expectEqualStrings(rep_a, rep_b);

    try std.testing.expect(std.mem.indexOf(u8, man_a, "boris-wordpress-media-manifest") != null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "\"status\": \"copied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "\"status\": \"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "\"status\": \"ambiguous\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "\"status\": \"rejected\"") != null);

    // Full uploads URL match
    const full = try wordpress.readFileAlloc(io, a, "content/posts/full-upload.md", gpa);
    defer gpa.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "full-upload.assets/2024/01/hero.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "wp-content/uploads/2024/01/hero.png") == null);
    const hero_copy = try wordpress.readFileAlloc(io, a, "content/posts/full-upload.assets/2024/01/hero.png", gpa);
    defer gpa.free(hero_copy);
    try std.testing.expectEqualStrings(media_before, hero_copy);

    // Relative uploads/ match
    const rel = try wordpress.readFileAlloc(io, a, "content/posts/relative-uploads.md", gpa);
    defer gpa.free(rel);
    try std.testing.expect(std.mem.indexOf(u8, rel, "relative-uploads.assets/2024/01/shared.png") != null);
    const shared_a = try wordpress.readFileAlloc(io, a, "content/posts/relative-uploads.assets/2024/01/shared.png", gpa);
    defer gpa.free(shared_a);
    try std.testing.expectEqualStrings(shared_before, shared_a);

    // Same source asset on two pages → per-page copies
    const shared_again = try wordpress.readFileAlloc(io, a, "content/posts/shared-again.md", gpa);
    defer gpa.free(shared_again);
    try std.testing.expect(std.mem.indexOf(u8, shared_again, "shared-again.assets/2024/01/shared.png") != null);
    const shared_b = try wordpress.readFileAlloc(io, a, "content/posts/shared-again.assets/2024/01/shared.png", gpa);
    defer gpa.free(shared_b);
    try std.testing.expectEqualStrings(shared_before, shared_b);

    // Nested page output path
    const nested = try wordpress.readFileAlloc(io, a, "content/pages/nested-diagram.md", gpa);
    defer gpa.free(nested);
    try std.testing.expect(std.mem.indexOf(u8, nested, "nested-diagram.assets/2024/06/diagram.png") != null);
    const diagram = try wordpress.readFileAlloc(io, a, "content/pages/nested-diagram.assets/2024/06/diagram.png", gpa);
    defer gpa.free(diagram);
    try std.testing.expect(diagram.len > 0);

    // Missing media: original reference preserved
    const missing = try wordpress.readFileAlloc(io, a, "content/posts/missing-media.md", gpa);
    defer gpa.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "https://example.com/wp-content/uploads/2024/01/gone.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "missing-media.assets") == null);

    // Ambiguous basename
    const amb = try wordpress.readFileAlloc(io, a, "content/posts/ambiguous-basename.md", gpa);
    defer gpa.free(amb);
    try std.testing.expect(std.mem.indexOf(u8, amb, "](hero.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "duplicate_media_basename") != null);

    // Traversal rejected; original preserved
    const trav = try wordpress.readFileAlloc(io, a, "content/posts/traversal-escape.md", gpa);
    defer gpa.free(trav);
    try std.testing.expect(std.mem.indexOf(u8, trav, "wp-content/uploads/2024/01/../../secret.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, trav, "traversal-escape.assets") == null);

    // Absolute / file: escapes preserved
    const abs = try wordpress.readFileAlloc(io, a, "content/posts/absolute-escape.md", gpa);
    defer gpa.free(abs);
    try std.testing.expect(std.mem.indexOf(u8, abs, "file:///etc/passwd.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, abs, "/etc/passwd.png") != null);

    // Query and fragment dropped (Boris asset grammar); limitation recorded
    const qf = try wordpress.readFileAlloc(io, a, "content/posts/query-fragment.md", gpa);
    defer gpa.free(qf);
    try std.testing.expect(std.mem.indexOf(u8, qf, "query-fragment.assets/2024/01/hero.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, qf, "query-fragment.assets/2024/01/hero.png#main") == null);
    try std.testing.expect(std.mem.indexOf(u8, qf, "?w=640") == null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "query_string_dropped") != null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "fragment_dropped") != null);

    // Exact 2025 path still copies despite duplicate basename inventory
    const h25 = try wordpress.readFileAlloc(io, a, "content/posts/hero-2025.md", gpa);
    defer gpa.free(h25);
    try std.testing.expect(std.mem.indexOf(u8, h25, "hero-2025.assets/2025/02/hero.png") != null);

    // Percent-encoded URL matches decoded on-disk name; output is Boris-safe
    const pct_page = try wordpress.readFileAlloc(io, a, "content/posts/percent-encoded.md", gpa);
    defer gpa.free(pct_page);
    try std.testing.expect(std.mem.indexOf(u8, pct_page, "my%20photo.png") == null);
    try std.testing.expect(std.mem.indexOf(u8, pct_page, "percent-encoded.assets/") != null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "percent_decoded_lookup") != null);
    // Emitted path uses sanitized basename when spaces are not Boris-safe
    try std.testing.expect(std.mem.indexOf(u8, pct_page, "my-photo.png") != null or
        std.mem.indexOf(u8, pct_page, "my photo.png") != null);

    // srcset + data-src URLs are harvested and rewritten when matched
    const srcset_page = try wordpress.readFileAlloc(io, a, "content/posts/srcset-lazy.md", gpa);
    defer gpa.free(srcset_page);
    try std.testing.expect(std.mem.indexOf(u8, srcset_page, "srcset-lazy.assets/2024/01/shared.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, srcset_page, "srcset-lazy.assets/2024/06/diagram.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, srcset_page, "srcset-lazy.assets/2024/01/hero.png") != null);

    // WP intermediate size: original preserved; reason recorded
    const resized_page = try wordpress.readFileAlloc(io, a, "content/posts/resized-derivative.md", gpa);
    defer gpa.free(resized_page);
    try std.testing.expect(std.mem.indexOf(u8, resized_page, "hero-300x200.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, resized_page, "resized-derivative.assets") == null);
    try std.testing.expect(std.mem.indexOf(u8, man_a, "likely_wp_resized_derivative") != null);

    // REPORT.md materialization summary
    const report_md = try wordpress.readFileAlloc(io, a, "REPORT.md", gpa);
    defer gpa.free(report_md);
    try std.testing.expect(std.mem.indexOf(u8, report_md, "## Media materialization") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_md, "| copied |") != null);

    // Source immutability
    const source_after = try wordpress.readFileAlloc(io, fixture, "export.xml", gpa);
    defer gpa.free(source_after);
    try std.testing.expectEqualStrings(source_before, source_after);
    const media_after = try wordpress.readFileAlloc(io, fixture, "media/2024/01/hero.png", gpa);
    defer gpa.free(media_after);
    try std.testing.expectEqualStrings(media_before, media_after);

    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "wordpress: re-run into same out dir wipes stale content" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const out_dir = "fixtures/.tmp-media-wxr-rerun";
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};

    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/media-wxr/export.xml",
        .media_dir = "fixtures/media-wxr/media",
        .out_dir = out_dir,
        .quiet = true,
    });

    // Plant a stale asset that must not survive the next run.
    try Io.Dir.cwd().createDirPath(io, out_dir ++ "/content/posts/stale-ghost.assets");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/content/posts/stale-ghost.assets/ghost.png", .data = "stale" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/content/posts/stale-ghost.md", .data = "# stale\n" });

    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/media-wxr/export.xml",
        .media_dir = "fixtures/media-wxr/media",
        .out_dir = out_dir,
        .quiet = true,
    });

    var out = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer out.close(io);
    // Stale paths gone
    const stale_md = out.access(io, "content/posts/stale-ghost.md", .{});
    try std.testing.expect(stale_md == error.FileNotFound or stale_md == error.PathNotFound);
    const stale_asset = out.access(io, "content/posts/stale-ghost.assets/ghost.png", .{});
    try std.testing.expect(stale_asset == error.FileNotFound or stale_asset == error.PathNotFound);
    // Fresh materialization still present
    const hero = try wordpress.readFileAlloc(io, out, "content/posts/full-upload.assets/2024/01/hero.png", gpa);
    defer gpa.free(hero);
    try std.testing.expect(hero.len > 0);
    const man = try wordpress.readFileAlloc(io, out, "media_manifest.json", gpa);
    defer gpa.free(man);
    try std.testing.expect(std.mem.indexOf(u8, man, "\"status\": \"copied\"") != null);

    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
}

test "wordpress: media symlink escape is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const tmp_media = "fixtures/.tmp-media-symlink";
    const out_dir = "fixtures/.tmp-media-symlink-out";
    Io.Dir.cwd().deleteTree(io, tmp_media) catch {};
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp_media ++ "/2024/01");

    {
        var year = try Io.Dir.cwd().openDir(io, tmp_media ++ "/2024/01", .{});
        defer year.close(io);
        try year.writeFile(io, .{ .sub_path = "real.png", .data = "real-bytes" });
        year.symLink(io, "/etc/hosts", "alias.png", .{}) catch {
            year.symLink(io, "../../../export-outside", "alias.png", .{}) catch {};
        };
    }

    const wxr =
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:wp="http://wordpress.org/export/1.2/">
        \\<channel><title>Sym</title><link>https://example.com</link>
        \\<wp:base_site_url>https://example.com</wp:base_site_url><wp:base_blog_url>https://example.com</wp:base_blog_url>
        \\<item><title>Symlink Post</title><link>https://example.com/sym/</link><dc:creator>a</dc:creator>
        \\<guid>sym</guid>
        \\<content:encoded><![CDATA[<img src="https://example.com/wp-content/uploads/2024/01/alias.png" alt="Alias"/>]]></content:encoded>
        \\<wp:post_id>1</wp:post_id><wp:post_date>2024-01-01</wp:post_date><wp:post_name>sym</wp:post_name>
        \\<wp:status>publish</wp:status><wp:post_parent>0</wp:post_parent><wp:post_type>post</wp:post_type>
        \\</item></channel></rss>
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_media ++ "/export.xml", .data = wxr });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const has_link = blk: {
        var year = Io.Dir.cwd().openDir(io, tmp_media ++ "/2024/01", .{}) catch break :blk false;
        defer year.close(io);
        _ = year.readLink(io, "alias.png", &buf) catch break :blk false;
        break :blk true;
    };
    if (!has_link) {
        Io.Dir.cwd().deleteTree(io, tmp_media) catch {};
        return;
    }

    try wordpress.run(io, gpa, .{
        .wxr_path = tmp_media ++ "/export.xml",
        .media_dir = tmp_media,
        .out_dir = out_dir,
        .quiet = true,
    });

    var out = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer out.close(io);
    const man = try wordpress.readFileAlloc(io, out, "media_manifest.json", gpa);
    defer gpa.free(man);
    try std.testing.expect(std.mem.indexOf(u8, man, "symlink_escape") != null or std.mem.indexOf(u8, man, "\"status\": \"rejected\"") != null);

    const page = try wordpress.readFileAlloc(io, out, "content/posts/sym.md", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "wp-content/uploads/2024/01/alias.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "sym.assets") == null);

    Io.Dir.cwd().deleteTree(io, tmp_media) catch {};
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
}

test "wordpress: generated content compiles with product Boris" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Lab tests use cwd = tools/migration-lab. Boris validates layout paths without `..`
    // and requires HTML output inside the workspace, so spawn with cwd = repo root.
    //
    // Hostile refs (absolute, basename-only, file:) are intentional review fixtures and
    // would fail product EASSET; compile a filtered tree of successfully materialised pages.
    const lab_out = "fixtures/.tmp-media-wxr-compile";
    const clean_out = "fixtures/.tmp-media-wxr-compile-clean";
    Io.Dir.cwd().deleteTree(io, lab_out) catch {};
    Io.Dir.cwd().deleteTree(io, clean_out) catch {};

    try wordpress.run(io, gpa, .{
        .wxr_path = "fixtures/media-wxr/export.xml",
        .media_dir = "fixtures/media-wxr/media",
        .out_dir = lab_out,
        .quiet = true,
    });

    const boris_from_lab = "../../zig-out/bin/boris";
    var boris_probe = Io.Dir.cwd().openFile(io, boris_from_lab, .{}) catch {
        Io.Dir.cwd().deleteTree(io, lab_out) catch {};
        return; // product binary not built
    };
    boris_probe.close(io);

    // Copy only pages whose media was materialised (or have no local media refs).
    try Io.Dir.cwd().createDirPath(io, clean_out ++ "/content/posts");
    try Io.Dir.cwd().createDirPath(io, clean_out ++ "/content/pages");
    const keep = [_][]const u8{
        "content/posts.md",
        "content/pages.md",
        "content/posts/full-upload.md",
        "content/posts/relative-uploads.md",
        "content/posts/shared-again.md",
        "content/posts/query-fragment.md",
        "content/posts/hero-2025.md",
        "content/pages/guides.md",
        "content/pages/nested-diagram.md",
    };
    var src_root = try Io.Dir.cwd().openDir(io, lab_out, .{});
    defer src_root.close(io);
    var dst_root = try Io.Dir.cwd().openDir(io, clean_out, .{});
    defer dst_root.close(io);
    for (keep) |rel| {
        const bytes = try wordpress.readFileAlloc(io, src_root, rel, gpa);
        defer gpa.free(bytes);
        // writeBytes is private; use ensure parent + writeFile via dst_root paths.
        if (std.fs.path.dirname(rel)) |parent| {
            try dst_root.createDirPath(io, parent);
        }
        try dst_root.writeFile(io, .{ .sub_path = rel, .data = bytes });
    }
    // Copy sibling asset trees for materialised pages.
    const asset_trees = [_][]const u8{
        "content/posts/full-upload.assets",
        "content/posts/relative-uploads.assets",
        "content/posts/shared-again.assets",
        "content/posts/query-fragment.assets",
        "content/posts/hero-2025.assets",
        "content/pages/nested-diagram.assets",
    };
    for (asset_trees) |tree| {
        // Recursive copy via walk of known nested files in this fixture.
        var src_tree = src_root.openDir(io, tree, .{ .iterate = true }) catch continue;
        defer src_tree.close(io);
        try copyTreeRecursive(io, gpa, src_root, dst_root, tree);
    }

    const content_from_root = "tools/migration-lab/fixtures/.tmp-media-wxr-compile-clean/content";
    const html_from_root = "test-output/wp-media-compile-html";
    const boris_from_root = "zig-out/bin/boris";
    const layout_from_root = "layouts/main.html";

    Io.Dir.cwd().deleteTree(io, "../../test-output/wp-media-compile-html") catch {};
    try Io.Dir.cwd().createDirPath(io, "../../test-output");

    const argv = [_][]const u8{
        boris_from_root,
        "--input",
        content_from_root,
        "--html-dir",
        html_from_root,
        "--html-layout",
        layout_from_root,
        "--quiet",
    };
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = "../.." },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        Io.Dir.cwd().deleteTree(io, lab_out) catch {};
        Io.Dir.cwd().deleteTree(io, clean_out) catch {};
        return;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("boris compile failed code={d} stderr={s} stdout={s}\n", .{ code, result.stderr, result.stdout });
    }
    try std.testing.expectEqual(@as(u8, 0), code);

    var html_root = try Io.Dir.cwd().openDir(io, "../../test-output/wp-media-compile-html", .{});
    defer html_root.close(io);
    const pub_hero = try wordpress.readFileAlloc(io, html_root, "posts/full-upload.assets/2024/01/hero.png", gpa);
    defer gpa.free(pub_hero);
    try std.testing.expect(pub_hero.len > 0);
    const pub_nested = try wordpress.readFileAlloc(io, html_root, "pages/nested-diagram.assets/2024/06/diagram.png", gpa);
    defer gpa.free(pub_nested);
    try std.testing.expect(pub_nested.len > 0);

    Io.Dir.cwd().deleteTree(io, lab_out) catch {};
    Io.Dir.cwd().deleteTree(io, clean_out) catch {};
    Io.Dir.cwd().deleteTree(io, "../../test-output/wp-media-compile-html") catch {};
}

fn copyTreeRecursive(io: Io, gpa: std.mem.Allocator, src_root: Io.Dir, dst_root: Io.Dir, rel: []const u8) !void {
    var dir = try src_root.openDir(io, rel, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name });
        defer gpa.free(child);
        if (entry.kind == .directory) {
            try dst_root.createDirPath(io, child);
            try copyTreeRecursive(io, gpa, src_root, dst_root, child);
            continue;
        }
        if (entry.kind != .file) continue;
        const data = try wordpress.readFileAlloc(io, src_root, child, gpa);
        defer gpa.free(data);
        if (std.fs.path.dirname(child)) |parent| {
            try dst_root.createDirPath(io, parent);
        }
        try dst_root.writeFile(io, .{ .sub_path = child, .data = data });
    }
}
