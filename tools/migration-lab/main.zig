//! boris-migration-lab — Astro → Boris migration archaeology (read-only).
//!
//! Scans an Astro project/export tree and emits deterministic JSON + Markdown
//! reports. Never rewrites source content. Not part of the Boris product
//! compiler pipeline.
//!
//! Usage (from tools/migration-lab/):
//!   zig build
//!   zig build run -- --root=./fixtures/mini-astro --out=./.out-report
//!   zig build test
//!
//! From repo root:
//!   zig build -C tools/migration-lab
//!   zig build -C tools/migration-lab test

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");

pub const format_id = archaeology.format_id;
pub const schema_version = archaeology.schema_version;
pub const tool_version = archaeology.tool_version;

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    io_error = 3,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub const Options = struct {
    help: bool = false,
    quiet: bool = false,
    /// Astro project/export root to scan (relative to cwd unless absolute).
    root_dir: []const u8 = ".",
    /// Report output directory (created if missing). Never writes into --root.
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
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            const value = arg["--root=".len..];
            if (value.len == 0) return error.MissingValue;
            options.root_dir = value;
        } else if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingValue;
            options.root_dir = args[index];
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
        \\boris-migration-lab — Astro → Boris migration archaeology (read-only)
        \\
        \\Usage:
        \\  boris-migration-lab [options]
        \\  zig build run -- [options]
        \\
        \\Options:
        \\  -h, --help       Show this help and exit
        \\  -q, --quiet      Suppress progress lines
        \\  --root=DIR       Astro project/export root to scan (default: .)
        \\  --out=DIR        Report directory (default: migration-report)
        \\
        \\Outputs (under --out only; never modifies --root):
        \\  report.json      Machine-readable findings (schema_version 1)
        \\  REPORT.md        Human-readable archaeology report
        \\
        \\Reports cover:
        \\  page/source inventory, three-file stitches, proposed Boris entity
        \\  ids, parent/child candidates, internal/broken links, slug conflicts,
        \\  assets + missing refs, frontmatter/content hazards, human-review
        \\  queue. Every finding includes source-relative provenance.
        \\
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

    if (std.mem.eql(u8, opts.root_dir, opts.out_dir)) {
        std.log.err("--out must differ from --root (refusing to write reports into the scan tree)", .{});
        return ExitCode.usage.int();
    }

    archaeology.run(io, gpa, .{
        .root_dir = opts.root_dir,
        .out_dir = opts.out_dir,
        .quiet = opts.quiet,
    }) catch |err| {
        std.log.err("migration-lab failed: {s}", .{@errorName(err)});
        return ExitCode.io_error.int();
    };
    return ExitCode.success.int();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseOptions: defaults and flags" {
    const o = try parseOptions(&.{"boris-migration-lab"});
    try std.testing.expect(!o.help);
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

test "parseOptions: unknown flag" {
    try std.testing.expectError(error.UnknownFlag, parseOptions(&.{ "x", "--rag" }));
}

test "entity id proposal from content path" {
    const id1 = archaeology.proposeEntityId("src/content/docs/guides/intro.md");
    try std.testing.expectEqualStrings("docs/guides/intro", id1);

    const id2 = archaeology.proposeEntityId("src/content/docs/index.mdx");
    try std.testing.expectEqualStrings("docs/index", id2);

    const id3 = archaeology.proposeEntityId("src/pages/about.astro");
    try std.testing.expectEqualStrings("about", id3);
}

test "slug derivation is deterministic" {
    try std.testing.expectEqualStrings(
        "guides/intro",
        archaeology.slugFromContentPath("src/content/docs/guides/intro.md"),
    );
    try std.testing.expectEqualStrings(
        "guides/intro",
        archaeology.slugFromContentPath("src/content/blog/guides/intro.mdx"),
    );
}

test "path helpers: normalize and classify" {
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

test "frontmatter hazard detection" {
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

test "link extraction" {
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

test "fixture scan produces stable report sections" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const out_rel = "fixtures/.test-out-report";
    // Clean previous run if any (owned by this package under fixtures/).
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

    // Provenance on findings.
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"source_path\": \"src/content/docs/guides/intro.md\"") != null);

    // Specific fixture signals.
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "duplicate") != null or
        std.mem.indexOf(u8, json_bytes, "slug_conflict") != null or
        std.mem.indexOf(u8, json_bytes, "\"slug_conflicts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, md_bytes, "# Astro → Boris migration archaeology") != null);
    try std.testing.expect(std.mem.indexOf(u8, md_bytes, "Human review") != null);

    // Determinism: run twice and compare JSON.
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

    // Cleanup owned test outputs.
    Io.Dir.cwd().deleteTree(io, out_rel) catch {};
    Io.Dir.cwd().deleteTree(io, out_rel2) catch {};
}

test "sources are never modified" {
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
