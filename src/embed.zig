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
const embed_evidence = @import("embed_evidence.zig");
const artifact_inventory = @import("artifact_inventory.zig");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");
const publication_touches = @import("publication_touches.zig");

pub const SourceFile = source_provider.File;

/// Content-class HTML faults: author-fixable failures that the native path
/// reports as structured diagnostics (layout/theme family, content scan and
/// parse faults), so the embed surface completes the compile with status 1
/// and diagnostics instead of an unexpected-error ABI code (#909). Anything
/// outside this closed set stays an embed ABI error, fail-closed.
fn isEmbedContentFault(err: anyerror) bool {
    return switch (err) {
        error.LayoutMissingMarker,
        error.LayoutDuplicateMarker,
        error.LayoutUnknownMarker,
        error.LayoutInvalidNavMarker,
        error.LayoutTooManySegments,
        error.LayoutInvalidAssetUrl,
        error.LayoutTooManyAssetUrls,
        error.LayoutInvalidUtf8,
        error.InvalidLayoutPath,
        error.LayoutSelectionFailed,
        error.AmbiguousGlob,
        error.DuplicateSelector,
        error.EmptySelector,
        error.InvalidSelector,
        error.UnknownSelectorKind,
        error.RuleLimitExceeded,
        error.InvalidSiteUrl,
        error.InvalidSitemapPath,
        error.SitemapOutputCollision,
        error.SitemapSiteUrlRequired,
        error.ThemeRootMissing,
        error.ThemeSymlink,
        error.InvalidThemePath,
        error.AssetNotFound,
        error.AssetCollision,
        error.AssetSymlink,
        error.AssetPathEscape,
        error.FooterSymlink,
        error.FooterInvalidUtf8,
        error.ParseFailed,
        error.InvalidPath,
        error.InputFormatMismatch,
        error.ContentDirMissing,
        error.FileNotFound,
        // The embed layout is read through the memory source provider, so a
        // layout missing from the bundle surfaces as SourceMissing (#909).
        error.SourceMissing,
        => true,
        else => false,
    };
}

/// Closed embed profile. First cut is Markdown IR; `html` adds Oliver HTML
/// through the same graph freeze and assemble splice. `evidence` adds the
/// target-local artifacts/checks/claims/touches chain after successful HTML.
pub const CompileConfig = struct {
    input_format: identity.InputFormat = .markdown,
    html: bool = false,
    evidence: bool = false,
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
        var html_diag = diag.Collector.init(gpa, io);
        var content_fault = false;
        var fault_err: anyerror = error.NoError;
        _ = compile_mod.compileHtmlToSink(io, gpa, .{
            .content_root = "",
            .dist_dir = "",
            .layout_path = config.layout_path,
            .quiet = true,
            .input_format = config.input_format,
            .sources = .{ .memory = &sources },
            .sink = .{ .memory = &sink },
            .diagnostics = &html_diag,
        }) catch |err| {
            // Embed misuse and system failures stay ABI errors. A
            // content-class fault (missing/broken layout, scan or parse
            // failure) is a completed compile with diagnostics (#909): it
            // surfaces through the normal bundle result (embed status 1)
            // with the mapped diagnostic, mirroring the native path, instead
            // of the opaque "unexpected compile error" ABI code.
            if (!isEmbedContentFault(err)) {
                html_diag.deinit();
                html_result.deinit();
                // `sink` is owned by the errdefer above; deinit-ing it here
                // as well would run the cleanup twice (#909).
                return err;
            }
            fault_err = err;
            content_fault = true;
        };
        if (content_fault) {
            html_result.ok = false;
            html_result.failure = .content;
            // A stage-level fault that carries no diagnostic of its own
            // (e.g. a theme-root fault after layout load) gets the same
            // mapping the native target path applies to every per-target
            // failure.
            if (html_diag.list.items.len == 0) {
                html_diag.append(.{
                    .severity = .error_,
                    .code = compile_mod.layoutCodeFor(fault_err),
                    .message = try std.fmt.allocPrint(gpa, "html compilation failed: {s}", .{@errorName(fault_err)}),
                    .remediation = diag.Code.remediationForLayout(compile_mod.layoutCodeFor(fault_err)),
                    .source_path = config.layout_path,
                });
            }
        }
        // Surface every diagnostic the HTML phase collected (warnings on
        // success, the mapped failure on a content fault) in the bundle
        // result; strings are copied into the result's arena because the
        // collector owns its own copies.
        const arena = html_result.arena.allocator();
        for (html_diag.list.items) |d| {
            html_result.diagnostics.append(gpa, .{
                .severity = d.severity,
                .code = d.code,
                .message = arena.dupe(u8, d.message) catch break,
                .remediation = arena.dupe(u8, d.remediation) catch break,
                .source_path = arena.dupe(u8, d.source_path) catch break,
                .line = d.line,
                .column = d.column,
                .id = arena.dupe(u8, d.id) catch break,
            }) catch break;
        }
        html_diag.deinit();
        if (content_fault) {
            return .{ .result = html_result, .artifacts = sink };
        }
        if (config.evidence) {
            embed_evidence.emit(gpa, &sink) catch |err| {
                html_result.deinit();
                sink.deinit();
                return err;
            };
        }
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

test "missing layout completes the compile with a mapped diagnostic (#909)" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "index.md", .bytes = home_md },
        .{ .path = "includes/tip.md", .bytes = tip_md },
    };
    // html:true with no layout in the bundle: an author-fixable content
    // fault, not an unexpected embed ABI error — the compile completes with
    // ok=false, a content failure, and the mapped ELAYOUT diagnostic.
    var compilation = try compileBundle(io, gpa, &files, .{ .html = true });
    defer compilation.deinit();
    try testing.expect(!compilation.ok());
    try testing.expectEqual(pipeline.FailureKind.content, compilation.result.failure);
    var mapped = false;
    for (compilation.diagnostics()) |d| {
        if (d.code == .ELAYOUT) mapped = true;
    }
    try testing.expect(mapped);
}

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

fn expectNoSuccessfulClaims(artifacts: *const artifact_sink.Memory) !void {
    try testing.expect(artifacts.get(artifact_inventory.output_path) == null);
    try testing.expect(artifacts.get(publication_checks.output_path) == null);
    try testing.expect(artifacts.get(publication_claims.output_path) == null);
    try testing.expect(artifacts.get(publication_touches.output_path) == null);
}

fn expectClaimStatus(claims_json: []const u8, id: []const u8, want: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, claims_json, .{});
    defer parsed.deinit();
    const claims = parsed.value.object.get("claims").?.array.items;
    for (claims) |claim| {
        if (std.mem.eql(u8, claim.object.get("id").?.string, id)) {
            try testing.expectEqualStrings(want, claim.object.get("status").?.string);
            return;
        }
    }
    return error.MissingClaim;
}

test "compileBundle evidence emits the target-local chain after successful HTML" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "index.md", .bytes = home_md },
        .{ .path = "includes/tip.md", .bytes = tip_md },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
        .{ .path = "index.assets/logo.svg", .bytes = "<svg/>\n" },
        .{ .path = "themes/demo/assets/site.css", .bytes = "body{}\n" },
    };
    var compilation = try compileBundle(io, gpa, &files, .{ .html = true, .evidence = true });
    defer compilation.deinit();
    try testing.expect(compilation.ok());

    const artifacts_json = compilation.artifacts.get(artifact_inventory.output_path) orelse return error.MissingArtifacts;
    const checks_json = compilation.artifacts.get(publication_checks.output_path) orelse return error.MissingChecks;
    const claims_json = compilation.artifacts.get(publication_claims.output_path) orelse return error.MissingClaims;
    const touches_json = compilation.artifacts.get(publication_touches.output_path) orelse return error.MissingTouches;
    try testing.expect(compilation.artifacts.get(artifact_inventory.proof_pack_output_path) == null);
    try testing.expect(compilation.artifacts.get(artifact_inventory.proof_index_output_path) == null);

    const artifacts = try std.json.parseFromSlice(std.json.Value, gpa, artifacts_json, .{});
    defer artifacts.deinit();
    try testing.expectEqualStrings(artifact_inventory.artifact_format, artifacts.value.object.get("format").?.string);
    try testing.expectEqualStrings(embed_evidence.target_name, artifacts.value.object.get("target").?.string);
    var saw_html = false;
    var saw_theme = false;
    var saw_content = false;
    var saw_search = false;
    for (artifacts.value.object.get("artifacts").?.array.items) |item| {
        const path = item.object.get("path").?.string;
        const kind = item.object.get("kind").?.string;
        if (std.mem.eql(u8, path, "index.html") and std.mem.eql(u8, kind, "html-page")) saw_html = true;
        if (std.mem.eql(u8, path, "themes/demo/assets/site.css") and std.mem.eql(u8, kind, "theme-asset")) saw_theme = true;
        if (std.mem.eql(u8, path, "index.assets/logo.svg") and std.mem.eql(u8, kind, "content-asset")) saw_content = true;
        if (std.mem.eql(u8, kind, "rendered-search")) saw_search = true;
        try testing.expect(std.mem.indexOf(u8, path, "_boris/proof/") == null);
        try testing.expect(!std.mem.eql(u8, path, "manifest.json"));
    }
    try testing.expect(saw_html);
    try testing.expect(saw_theme);
    try testing.expect(saw_content);
    try testing.expect(!saw_search);

    const checks = try std.json.parseFromSlice(std.json.Value, gpa, checks_json, .{});
    defer checks.deinit();
    try testing.expectEqualStrings(publication_checks.report_format, checks.value.object.get("format").?.string);
    const check_rows = checks.value.object.get("checks").?.array.items;
    try testing.expectEqual(@as(usize, 3), check_rows.len);
    try testing.expectEqualStrings("artifact-integrity", check_rows[0].object.get("id").?.string);
    try testing.expectEqualStrings("passed", check_rows[0].object.get("status").?.string);
    try testing.expectEqualStrings("rendered-search", check_rows[2].object.get("id").?.string);
    try testing.expectEqualStrings("not-applicable", check_rows[2].object.get("status").?.string);

    try expectClaimStatus(claims_json, "committed-artifacts-match-inventory", "verified");
    try expectClaimStatus(claims_json, "rendered-search-matches-selected-html", "not-verified");

    const touches = try std.json.parseFromSlice(std.json.Value, gpa, touches_json, .{});
    defer touches.deinit();
    try testing.expectEqualStrings(publication_touches.report_format, touches.value.object.get("format").?.string);

    var again = try compileBundle(io, gpa, &files, .{ .html = true, .evidence = true });
    defer again.deinit();
    try testing.expectEqualStrings(artifacts_json, again.artifacts.get(artifact_inventory.output_path).?);
    try testing.expectEqualStrings(checks_json, again.artifacts.get(publication_checks.output_path).?);
    try testing.expectEqualStrings(claims_json, again.artifacts.get(publication_claims.output_path).?);
    try testing.expectEqualStrings(touches_json, again.artifacts.get(publication_touches.output_path).?);
}

test "compileBundle evidence is withheld when graph validation fails" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "orphan.md", .bytes = "---\ntitle: Orphan\nparent: missing\n---\n# Orphan\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    var compilation = try compileBundle(io, gpa, &files, .{ .html = true, .evidence = true });
    defer compilation.deinit();
    try testing.expect(!compilation.ok());
    try expectNoSuccessfulClaims(&compilation.artifacts);
}

const PoisonCase = struct {
    name: []const u8,
    files: []const SourceFile,
    code: diag.Code,
    source_path: []const u8,
};

fn sourcePathAllowed(case: PoisonCase, path: []const u8) bool {
    if (std.mem.eql(u8, case.source_path, path)) return true;
    // Parent-cycle reports land on one participant; either file is valid.
    if (case.code == .EPARENTCYCLE) {
        for (case.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return true;
        }
    }
    return false;
}

fn expectPoisonedParity(case: PoisonCase) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var bundle = try compileBundle(io, gpa, case.files, .{ .html = true, .evidence = true });
    defer bundle.deinit();
    try testing.expect(!bundle.ok());
    try expectNoSuccessfulClaims(&bundle.artifacts);

    var found = false;
    for (bundle.diagnostics()) |d| {
        if (d.code == case.code) {
            found = true;
            try testing.expectEqual(diag.Severity.error_, d.severity);
            try testing.expect(sourcePathAllowed(case, d.source_path));
            try testing.expect(d.line != null);
            try testing.expect(d.remediation.len > 0);
        }
    }
    try testing.expect(found);
}

test "compileBundle poisoned corpus withholds claims and keeps diagnostic fields" {
    const parent_files = [_]SourceFile{
        .{ .path = "orphan.md", .bytes = "---\ntitle: Orphan\nparent: missing\n---\n# Orphan\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "missing-parent",
        .files = &parent_files,
        .code = .EPARENTMISSING,
        .source_path = "orphan.md",
    });

    const cycle_files = [_]SourceFile{
        .{ .path = "a.md", .bytes = "---\ntitle: A\nparent: b\n---\n# A\n" },
        .{ .path = "b.md", .bytes = "---\ntitle: B\nparent: a\n---\n# B\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "cycle",
        .files = &cycle_files,
        .code = .EPARENTCYCLE,
        .source_path = "a.md",
    });

    const self_files = [_]SourceFile{
        .{ .path = "loop.md", .bytes = "---\ntitle: Loop\nparent: loop\n---\n# Loop\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "self-parent",
        .files = &self_files,
        .code = .EPARENTSELF,
        .source_path = "loop.md",
    });

    const frontmatter_files = [_]SourceFile{
        .{ .path = "bad.md", .bytes = "---\ntitle: Bad\nextra: value\n---\n# Body\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "unknown-key",
        .files = &frontmatter_files,
        .code = .EFRONTMATTER,
        .source_path = "bad.md",
    });

    const status_files = [_]SourceFile{
        .{ .path = "bad-status.md", .bytes = "---\ntitle: Bad Status\nstatus: shipping\n---\n# Body\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "invalid-status",
        .files = &status_files,
        .code = .EFRONTMATTER,
        .source_path = "bad-status.md",
    });

    const dup_files = [_]SourceFile{
        .{ .path = "alpha.md", .bytes = "---\nid: shared\ntitle: Alpha\n---\n# Alpha\n" },
        .{ .path = "beta.md", .bytes = "---\nid: shared\ntitle: Beta\n---\n# Beta\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "duplicate-ids",
        .files = &dup_files,
        .code = .EDUPLICATEID,
        .source_path = "beta.md",
    });

    const include_files = [_]SourceFile{
        .{ .path = "index.md", .bytes = "---\ntitle: Home\nstatus: published\n---\n# Home\n\n{{include includes/missing.md}}\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "missing-include",
        .files = &include_files,
        .code = .EINCLUDEMISSING,
        .source_path = "index.md",
    });

    const wiki_files = [_]SourceFile{
        .{ .path = "index.md", .bytes = "---\nid: index\ntitle: Home\n---\n# Home\n\nBroken: [[no/such/page]].\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "wiki-missing-target",
        .files = &wiki_files,
        .code = .EREFERENCEMISSING,
        .source_path = "index.md",
    });

    const utf8_files = [_]SourceFile{
        .{ .path = "bad-utf8.md", .bytes = "---\ntitle: Bad\n---\n# Body\n\n\xff\n" },
        .{ .path = "layouts/main.html", .bytes = embed_layout },
    };
    try expectPoisonedParity(.{
        .name = "invalid-utf8",
        .files = &utf8_files,
        .code = .EINVALIDUTF8,
        .source_path = "bad-utf8.md",
    });
}

test "compileBundle poisoned corpus matches native filesystem diagnostic fields" {
    const gpa = testing.allocator;
    const io = testing.io;
    const files = [_]SourceFile{
        .{ .path = "orphan.md", .bytes = "---\ntitle: Orphan\nparent: does-not-exist\n---\n# Orphan\n\nParent id is not present in the content set.\n" },
    };
    var bundle = try compileBundle(io, gpa, &files, .{});
    defer bundle.deinit();

    var fs = try pipeline.compile(io, gpa, .{
        .content_root = "docs/contracts/fixtures/missing-parent/content",
        .quiet = true,
    });
    defer fs.deinit();

    try testing.expect(!bundle.ok());
    try testing.expect(!fs.ok);
    try testing.expectEqual(fs.diagnostics.items.len, bundle.diagnostics().len);
    for (fs.diagnostics.items, bundle.diagnostics()) |want, got| {
        try testing.expectEqual(want.code, got.code);
        try testing.expectEqual(want.severity, got.severity);
        try testing.expectEqualStrings(want.source_path, got.source_path);
        try testing.expectEqual(want.line, got.line);
        try testing.expectEqual(want.column, got.column);
        try testing.expectEqualStrings(want.remediation, got.remediation);
    }
}
