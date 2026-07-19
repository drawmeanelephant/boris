//! boris-migration-lab — standalone migration archaeology tools.
//!
//! Modes:
//!   astro             — read-only Astro tree scan → report.json + REPORT.md
//!   wordpress         — WordPress WXR → Boris Markdown + reports
//!   instagram         — Instagram Takeout dump → Boris Markdown + theme assets + reports
//!   obsidian          — Obsidian vault → Boris Markdown + attachments + reports
//!   notion            — Notion Markdown & CSV export → Boris Markdown + media + reports
//!   filed             — Filed.fyi changelog + releases slice → Boris Markdown + reports
//!   starlight         — Starlight/Astro docs dogfood (locale-dir or root-locale) → Boris candidate + boundary manifests
//!   asset-filename    — Sanitize content-local asset filenames to Boris ASCII path grammar
//!   theme-archaeology — Read-only Astro/Starlight theme inventory → adaptation ledger + boundary report
//!   theme-materialize — Ledger-driven safe static Boris theme materialization
//!   wordpress-theme   — Read-only classic WordPress PHP theme inventory → static prototype + review manifest
//!   frontmatter-review — Scan a content tree for unsupported frontmatter keys → JSON + MD report
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
//!   zig build run -- --mode=frontmatter-review --content=./content --out=./.out-fmreview
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
const link_audit = @import("link_audit.zig");
const frontmatter_review = @import("frontmatter_review.zig");

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
    link_audit,
    frontmatter_review,

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
        if (std.mem.eql(u8, s, "link-audit") or std.mem.eql(u8, s, "links") or
            std.mem.eql(u8, s, "output-audit")) return .link_audit;
        if (std.mem.eql(u8, s, "frontmatter-review") or std.mem.eql(u8, s, "fm-review") or
            std.mem.eql(u8, s, "fmreview"))
            return .frontmatter_review;
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
    /// Content tree root for frontmatter-review mode.
    content_dir: ?[]const u8 = null,
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
        } else if (std.mem.startsWith(u8, arg, "--content=")) {
            const value = arg["--content=".len..];
            if (value.len == 0) return error.MissingValue;
            options.content_dir = value;
            options.mode = .frontmatter_review;
        } else if (std.mem.eql(u8, arg, "--content")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.content_dir = args[index];
            options.mode = .frontmatter_review;
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
        \\  --mode=MODE        astro (default) | wordpress | wordpress-theme | instagram | obsidian | notion | filed | starlight | asset-filename | theme-archaeology | theme-materialize | link-audit | frontmatter-review
        \\  --out=DIR          Output directory (default: migration-report)
        \\
        \\Frontmatter review (read-only unsupported-key audit):
        \\  --mode=frontmatter-review  Scan a content tree for keys outside the Boris
        \\                     closed grammar {id, title, parent, status, tags}
        \\  --content=DIR      Content tree root (required; never modified)
        \\  Writes: frontmatter_review.json, FRONTMATTER_REVIEW.md
        \\  Aliases: fm-review | fmreview
        \\  (--content implies --mode=frontmatter-review)
        \\  No source file is modified. Unclosed fences are flagged, not crashed on.
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
        \\Link audit (generated-output validation):
        \\  --mode=link-audit   Scan static HTML output for missing local routes/fragments
        \\  --root=DIR          Generated HTML tree (required; never modified)
        \\  Writes: link_audit.json, REPORT.md
        \\  External, mailto, tel, data, and hash-only links are not audited.
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
        .link_audit => {
            if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
                std.log.err("--out must differ from --root", .{});
                return ExitCode.usage.int();
            }
            link_audit.run(io, gpa, .{
                .root_dir = opts.root_dir,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (link-audit) failed: {s}", .{@errorName(err)});
                return ExitCode.io_error.int();
            };
        },
        .frontmatter_review => {
            const content = opts.content_dir orelse {
                std.log.err("frontmatter-review mode requires --content=DIR", .{});
                printUsage();
                return ExitCode.usage.int();
            };
            if (std.mem.eql(u8, content, opts.out_dir)) {
                std.log.err("--out must differ from --content", .{});
                return ExitCode.usage.int();
            }
            frontmatter_review.run(io, gpa, .{
                .source_root = content,
                .out_dir = opts.out_dir,
                .quiet = opts.quiet,
            }) catch |err| {
                std.log.err("migration-lab (frontmatter-review) failed: {s}", .{@errorName(err)});
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
    _ = frontmatter_review;
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

test "parseOptions: frontmatter-review flags" {
    const o = try parseOptions(&.{
        "boris-migration-lab",
        "--content=fixtures/fm-review-mixed",
        "--out=./.fmreview-out",
    });
    try std.testing.expect(o.mode == .frontmatter_review);
    try std.testing.expectEqualStrings("fixtures/fm-review-mixed", o.content_dir.?);
    try std.testing.expectEqualStrings("./.fmreview-out", o.out_dir);

    const o2 = try parseOptions(&.{ "boris-migration-lab", "--mode=frontmatter-review", "--content", "./c", "--out", "./o" });
    try std.testing.expect(o2.mode == .frontmatter_review);
    try std.testing.expectEqualStrings("./c", o2.content_dir.?);

    const o3 = try parseOptions(&.{ "boris-migration-lab", "--mode=fm-review", "--content=./c", "--out=./o" });
    try std.testing.expect(o3.mode == .frontmatter_review);

    const o4 = try parseOptions(&.{ "boris-migration-lab", "--mode=fmreview", "--content=./c", "--out=./o" });
    try std.testing.expect(o4.mode == .frontmatter_review);
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
}
