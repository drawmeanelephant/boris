//! Public embedding compile entry (#301 M3).
//!
//! Files in → same parse/graph/validate → diagnostics and IR artifacts out.
//! Memory adapters do not open a host directory or write an output tree.
//! This is not a publication target and is not the Wasm ABI (M5).

const std = @import("std");
const Io = std.Io;
const pipeline = @import("pipeline.zig");
const compile_mod = @import("compile.zig");
const source_provider = @import("source_provider.zig");
const artifact_sink = @import("artifact_sink.zig");
const identity = @import("identity.zig");
const diag = @import("diag.zig");

pub const SourceFile = source_provider.File;

/// Closed embed profile. First cut is Markdown IR; `html` adds Oliver HTML
/// through the same graph freeze and assemble splice.
pub const CompileConfig = struct {
    input_format: identity.InputFormat = .markdown,
    html: bool = false,
    layout_path: []const u8 = "layouts/main.html",
};

pub const Compilation = struct {
    result: pipeline.Result,
    artifacts: artifact_sink.Memory,

    pub fn deinit(self: *Compilation) void {
        self.artifacts.deinit();
        self.result.deinit();
    }

    pub fn ok(self: *const Compilation) bool {
        return self.result.ok;
    }

    pub fn diagnostics(self: *const Compilation) []const diag.Diagnostic {
        return self.result.diagnostics.items;
    }
};

/// Compile a canonical source bundle. `io` is required by the shared pipeline
/// type; the memory adapters do not use cwd, scan a host directory, or write
/// an output tree.
pub fn compileBundle(
    io: Io,
    gpa: std.mem.Allocator,
    files: []const SourceFile,
    config: CompileConfig,
) !Compilation {
    var sources = try source_provider.Memory.init(gpa, files, config.input_format);
    defer sources.deinit();
    var sink = artifact_sink.Memory.init(gpa);
    errdefer sink.deinit();

    const result = try pipeline.run(io, gpa, .{
        .content_root = "",
        .out_dir = "",
        .quiet = true,
        .input_format = config.input_format,
        .sources = .{ .memory = &sources },
        .sink = .{ .memory = &sink },
    });
    if (result.ok and config.html) {
        var html_result = result;
        _ = compile_mod.compileHtmlToSink(io, gpa, .{
            .content_root = "",
            .dist_dir = "",
            .layout_path = config.layout_path,
            .quiet = true,
            .input_format = config.input_format,
            .sources = .{ .memory = &sources },
            .sink = .{ .memory = &sink },
        }) catch |err| {
            html_result.deinit();
            sink.deinit();
            return err;
        };
        return .{
            .result = html_result,
            .artifacts = sink,
        };
    }
    return .{
        .result = result,
        .artifacts = sink,
    };
}

const testing = std.testing;

const home_md =
    \\---
    \\title: Home
    \\status: published
    \\---
    \\# Home
    \\
    \\{{include includes/tip.md}}
    \\
;

const tip_md = "a tip\n";

test "compileBundle emits IR for a valid memory bundle" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "index.md", .bytes = home_md },
        .{ .path = "includes/tip.md", .bytes = tip_md },
    };
    var compilation = try compileBundle(io, gpa, &files, .{});
    defer compilation.deinit();
    try testing.expect(compilation.ok());
    try testing.expectEqual(@as(usize, 0), diag.countErrors(compilation.diagnostics()));
    try testing.expect(compilation.artifacts.get("manifest.json") != null);
    try testing.expect(compilation.artifacts.get("graph.json") != null);
    try testing.expect(compilation.artifacts.get("completion.json") != null);
    try testing.expect(compilation.artifacts.get("build-report.json") != null);
}

test "compileBundle matches pipeline.run on the same memory files" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "index.md", .bytes = home_md },
        .{ .path = "includes/tip.md", .bytes = tip_md },
    };
    var compilation = try compileBundle(io, gpa, &files, .{});
    defer compilation.deinit();

    var sources = try source_provider.Memory.init(gpa, &files, .markdown);
    defer sources.deinit();
    var sink = artifact_sink.Memory.init(gpa);
    defer sink.deinit();
    var direct = try pipeline.run(io, gpa, .{
        .content_root = "",
        .out_dir = "",
        .quiet = true,
        .sources = .{ .memory = &sources },
        .sink = .{ .memory = &sink },
    });
    defer direct.deinit();

    try testing.expectEqual(direct.ok, compilation.ok());
    try testing.expectEqualStrings(sink.get("manifest.json").?, compilation.artifacts.get("manifest.json").?);
    try testing.expectEqualStrings(sink.get("graph.json").?, compilation.artifacts.get("graph.json").?);
    try testing.expectEqualStrings(sink.get("completion.json").?, compilation.artifacts.get("completion.json").?);
    try testing.expectEqualStrings(sink.get("build-report.json").?, compilation.artifacts.get("build-report.json").?);
}

test "compileBundle invalid parent has equivalent diagnostic and no graph IR" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "orphan.md", .bytes = "---\ntitle: Orphan\nparent: missing\n---\n# Orphan\n" },
    };
    var compilation = try compileBundle(io, gpa, &files, .{});
    defer compilation.deinit();
    try testing.expect(!compilation.ok());
    try testing.expect(!compilation.result.published_graph_ir);
    try testing.expect(compilation.artifacts.get("manifest.json") == null);
    try testing.expect(compilation.artifacts.get("graph.json") == null);
    try testing.expect(compilation.artifacts.get("build-report.json") != null);

    var found = false;
    for (compilation.diagnostics()) |d| {
        if (d.code == .EPARENTMISSING) {
            found = true;
            try testing.expectEqual(diag.Severity.error_, d.severity);
            try testing.expectEqualStrings("orphan.md", d.source_path);
            try testing.expectEqual(@as(?u32, 1), d.line);
            try testing.expect(d.column != null);
            try testing.expect(d.remediation.len > 0);
        }
    }
    try testing.expect(found);
}

test "compileBundle of the valid fixture matches filesystem page ids" {
    const gpa = testing.allocator;
    const io = testing.io;
    const index = try Io.Dir.cwd().readFileAlloc(io, "docs/contracts/fixtures/valid/content/index.md", gpa, .limited(64 * 1024));
    defer gpa.free(index);
    const intro = try Io.Dir.cwd().readFileAlloc(io, "docs/contracts/fixtures/valid/content/guides/intro.md", gpa, .limited(64 * 1024));
    defer gpa.free(intro);
    const tips = try Io.Dir.cwd().readFileAlloc(io, "docs/contracts/fixtures/valid/content/guides/intro-tips.md", gpa, .limited(64 * 1024));
    defer gpa.free(tips);
    const files = [_]SourceFile{
        .{ .path = "index.md", .bytes = index },
        .{ .path = "guides/intro.md", .bytes = intro },
        .{ .path = "guides/intro-tips.md", .bytes = tips },
    };
    var compilation = try compileBundle(io, gpa, &files, .{});
    defer compilation.deinit();
    try testing.expect(compilation.ok());
    try testing.expectEqual(@as(usize, 3), compilation.result.pages.items.len);
    try testing.expectEqualStrings("guides/intro", compilation.result.pages.items[0].id);
    try testing.expectEqualStrings("guides/intro-tips", compilation.result.pages.items[1].id);
    try testing.expectEqualStrings("index", compilation.result.pages.items[2].id);
}

const embed_layout =
    \\<!DOCTYPE html><html><head><title>{{title}}</title></head><body>{{content}}</body></html>
;

test "compileBundle html emits Oliver pages through the sink" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "index.md", .bytes = home_md },
        .{ .path = "includes/tip.md", .bytes = tip_md },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    var compilation = try compileBundle(io, gpa, &files, .{ .html = true });
    defer compilation.deinit();
    try testing.expect(compilation.ok());
    const html = compilation.artifacts.get("index.html") orelse return error.MissingHtml;
    try testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"home\">Home</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "a tip") != null);
    try testing.expect(compilation.artifacts.get("manifest.json") != null);
}

test "compileBundle html copies page-sibling and theme assets from the bundle" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "index.md", .bytes = "---\ntitle: Home\nstatus: published\n---\n# Home\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
        .{ .path = "index.assets/logo.svg", .bytes = "<svg/>\n" },
        .{ .path = "themes/demo/assets/site.css", .bytes = "body{}\n" },
    };
    var compilation = try compileBundle(io, gpa, &files, .{ .html = true });
    defer compilation.deinit();
    try testing.expect(compilation.ok());
    try testing.expectEqualStrings("<svg/>\n", compilation.artifacts.get("index.assets/logo.svg").?);
    try testing.expectEqualStrings("body{}\n", compilation.artifacts.get("themes/demo/assets/site.css").?);
}

test "compileBundle html is withheld when graph validation fails" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "orphan.md", .bytes = "---\ntitle: Orphan\nparent: missing\n---\n# Orphan\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    var compilation = try compileBundle(io, gpa, &files, .{ .html = true });
    defer compilation.deinit();
    try testing.expect(!compilation.ok());
    try testing.expect(compilation.artifacts.get("index.html") == null);
    try testing.expect(compilation.artifacts.get("orphan.html") == null);
}
