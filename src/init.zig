//! `boris init`: materialize a deterministic starter site and prove it compiles.
//!
//! Writes a small, comprehensible tree that builds and validates out of the
//! box: three Markdown pages exercising the graph (trunk, satellite, wiki
//! links, a semantic relation), a starter theme using the closed layout
//! slots with a working browser search client, and a publication profile
//! ready for `boris plan --profile`.
//!
//! After materializing, `init` compiles the fresh tree into a probe output
//! directory and deletes it again. Exit 0 therefore means "materialized AND
//! compiled": agents and scripts can assert the stronger postcondition, and
//! a starter that ever stops compiling fails loudly instead of shipping.
//!
//! The tree is byte-deterministic: every file is a fixed constant, so two
//! runs in identical conditions produce identical trees. `init` refuses to
//! touch an existing non-empty directory — no archaeology, and no silent
//! clobbering.

const std = @import("std");
const compile = @import("compile.zig");
const diagnostic = @import("diagnostic.zig");
const Io = std.Io;

const ExitCode = diagnostic.ExitCode;

const starter_layout = @embedFile("init_templates/layouts/main.html");
const starter_css = @embedFile("init_templates/assets/css/boris.css");

const index_md =
    \\---
    \\title: My Boris Site
    \\tags: [home]
    \\---
    \\
    \\# Welcome
    \\
    \\This is a fresh [Boris](https://github.com/drawmeanelephant/boris)
    \\documentation site. It already has a page graph: this trunk page,
    \\two guides beneath it, wiki links between them, and one semantic
    \\relation.
    \\
    \\Start here:
    \\
    \\- [[guides/getting-started]] — add your own pages and watch the graph grow.
    \\- [[guides/publishing]] — turn the site into a verified publication.
    \\
    \\## Anatomy of this starter
    \\
    \\The tree `boris init` created:
    \\
    \\```text
    \\content/
    \\  index.md                    trunk page (this one)
    \\  guides/getting-started.md   satellite, parent: index
    \\  guides/publishing.md        satellite, parent: index
    \\themes/boris/                 starter theme (closed layout slots, search UI)
    \\boris.json                    publication profile (GitHub Pages)
    \\standard-site.json            Atmosphere profile (edit the fake DID/URL)
    \\```
    \\
    \\Search is wired up: the compiler publishes
    \\`dist/_boris/search/search-index.json` and this theme ships the
    \\no-dependency browser client that queries it. Press `/` on any page.
    \\
;

const getting_started_md =
    \\---
    \\title: Getting Started
    \\parent: index
    \\tags: [guides]
    \\---
    \\
    \\# Getting Started
    \\
    \\A page is one Markdown file with YAML frontmatter. The frontmatter
    \\`id` is derived from the path unless you write one; `title`, `tags`,
    \\and `parent` shape the graph.
    \\
    \\## Add a page
    \\
    \\Create `content/guides/example.md`:
    \\
    \\```markdown
    \\---
    \\title: Example
    \\parent: index
    \\tags: [guides]
    \\---
    \\
    \\# Example
    \\
    \\Hello from [[index]].
    \\```
    \\
    \\Rebuild with `boris --input content --html-dir dist --theme themes/boris`
    \\and the page appears in the nav forest, the breadcrumb chain, and the
    \\frozen graph.
    \\
    \\## Frontmatter at a glance
    \\
    \\- `title` — page title (`{{title}}`, search, and metadata).
    \\- `parent` — entity id of the structural parent (this page lives under
    \\  `index`).
    \\- `tags` — free-form list rendered into page metadata.
    \\- `relations` — semantic edges such as `[relates_to=target]`; see
    \\  [semantic relations](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/semantic-relations.md).
    \\
    \\A wiki link `[[getting-started]]` is a real graph edge: a link to a
    \\missing page fails the build instead of rendering as dead prose.
    \\
;

const publishing_md =
    \\---
    \\title: Publishing
    \\parent: index
    \\tags: [guides]
    \\relations: [relates_to=guides/getting-started]
    \\---
    \\
    \\# Publishing
    \\
    \\Boris treats the deployment URL as publication truth, not an incidental
    \\detail. The starter profile declares one public HTML target:
    \\
    \\```json
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/boris" }
    \\  ]
    \\}
    \\```
    \\
    \\Inspect the normalized plan before publishing:
    \\
    \\```text
    \\boris plan --profile boris.json
    \\boris standard-site plan --profile standard-site.json
    \\```
    \\
    \\The official GitHub Pages workflow (see the repository's
    \\`docs/github-pages.md`) builds a verified target: it resolves the Pages
    \\location from `actions/configure-pages`, fails on any URL projection
    \\that disagrees with it, uploads only inventory-verified files, and
    \\retains a separate evidence artifact. Atmosphere publication uses
    \\`standard-site.json`: replace the obviously-fake DID and URL
    \\before `standard-site publish`. This starter page is related to
    \\[[guides/getting-started]] so the semantic graph has an edge to inspect.
    \\
;

const starter_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "site": { "title": "My Boris Site" },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/boris" }
    \\  ]
    \\}
    \\
;

/// Obviously fake Atmosphere identity. The DID is syntactically valid
/// `did:plc` (24 `a`s) and the URL is not a real public site. Testers must
/// replace both. `pds` is omitted: publish binds to the discovered PDS.
const standard_site_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "site": { "title": "My Boris Site" },
    \\  "publication": {
    \\    "target": "standard-site",
    \\    "base_url": "https://replace-me.example.com/",
    \\    "origin": "https://replace-me.example.com/",
    \\    "base_path": "",
    \\    "did": "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
    \\    "name": "My Boris Site",
    \\    "show_in_discover": false,
    \\    "prune": false
    \\  },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/boris" }
    \\  ]
    \\}
    \\
;

const FileToWrite = struct {
    path: []const u8,
    data: []const u8,
};

/// Every file `init` writes, in fixed order, with fixed bytes.
const files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = index_md },
    .{ .path = "content/guides/getting-started.md", .data = getting_started_md },
    .{ .path = "content/guides/publishing.md", .data = publishing_md },
    .{ .path = "themes/boris/layouts/main.html", .data = starter_layout },
    .{ .path = "themes/boris/assets/css/boris.css", .data = starter_css },
    .{ .path = "boris.json", .data = starter_profile },
    .{ .path = "standard-site.json", .data = standard_site_profile },
};

/// Create `sub_path` (including any missing parents) relative to `dir`,
/// tolerating an existing leaf directory. `Io.Dir.createDir` creates exactly
/// one level, so a nested target like `projects/site` needs the full-path
/// variant to build its parents.
fn createDirIfMissing(io: Io, dir: Io.Dir, sub_path: []const u8) !void {
    dir.createDirPath(io, sub_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Write the starter tree under `target_dir`, which must not exist yet or
/// must be empty. Returns an allocator-owned message on refusal so the
/// caller can explain the failure without guessing.
pub fn materialize(io: Io, gpa: std.mem.Allocator, target_dir: []const u8) ![]const u8 {
    const cwd = Io.Dir.cwd();
    createDirIfMissing(io, cwd, target_dir) catch |err| {
        return std.fmt.allocPrint(gpa, "cannot create target directory: {s}", .{@errorName(err)});
    };
    var dir = try cwd.openDir(io, target_dir, .{ .iterate = true });
    defer dir.close(io);

    // Refuse to clobber an existing project. Empty is fine (a user may point
    // init at a fresh checkout).
    var it = dir.iterate();
    if (try it.next(io)) |_| {
        return gpa.dupe(u8, "target directory is not empty; refusing to overwrite an existing site");
    }

    // If any write fails midway (permission, disk, I/O), remove the partial
    // tree so the next invocation can retry without manual cleanup. Installed
    // only after the emptiness check: a refusal writes nothing and must never
    // delete user content.
    errdefer cwd.deleteTree(io, target_dir) catch {};

    // One level at a time: Io.Dir.createDir creates exactly one level, so
    // every parent prefix is created explicitly, in order.
    const dirs = [_][]const u8{
        "content",
        "content/guides",
        "themes",
        "themes/boris",
        "themes/boris/layouts",
        "themes/boris/assets",
        "themes/boris/assets/css",
    };
    for (dirs) |d| {
        try dir.createDir(io, d, .default_dir);
    }

    for (files) |f| {
        try dir.writeFile(io, .{ .sub_path = f.path, .data = f.data });
    }
    return "";
}

/// Compile the freshly materialized starter into a probe output directory,
/// then remove the probe tree. `init` writes a starter tree, not a built
/// site, so the probe output never survives a successful run.
///
/// All probe paths are derived relative to the process working directory,
/// even when `target_dir` was spelled absolute: layout paths are
/// contractually required to be clean relative paths
/// (`layout_select.validateLayoutPath`), and every generated probe path is
/// resolved against the workspace like any other output tree. A target
/// outside the workspace cannot host the probe at all; the caller is told so
/// it can report the skipped verification honestly instead of pretending.
///
/// The probe lives inside `target_dir` (which `init` owns: the directory was
/// empty before it ran), keeping every generated path inside the target like
/// any other output tree. A crashed probe can leave the directory non-empty,
/// which the next `init` refuses with its normal message — the same failure
/// shape as a crash during materialization.
pub const ProbeResult = union(enum) {
    /// Pages compiled from the starter tree.
    verified: usize,
    /// Target resolves outside the workspace; probe skipped (reported).
    skipped,
};

fn verifyStarter(io: Io, gpa: std.mem.Allocator, target_dir: []const u8) !ProbeResult {
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target_abs = try std.fs.path.resolve(gpa, &.{ cwd, target_dir });
    defer gpa.free(target_abs);
    const rel_target = try std.fs.path.relative(gpa, cwd, null, cwd, target_abs);
    defer gpa.free(rel_target);

    // Outside the workspace: the probe's output tree would violate the same
    // containment rule every other generated output obeys.
    if (std.mem.startsWith(u8, rel_target, "..")) return .skipped;

    // `init .` into a fresh empty cwd is legal (relative() then returns an
    // empty or "." path); path.join skips empty parts.
    const base: []const u8 = if (std.mem.eql(u8, rel_target, ".")) "" else rel_target;

    const content_root = try std.fs.path.join(gpa, &.{ base, "content" });
    defer gpa.free(content_root);
    const layout_path = try std.fs.path.join(gpa, &.{ base, "themes/boris/layouts/main.html" });
    defer gpa.free(layout_path);
    const probe_dist = try std.fs.path.join(gpa, &.{ base, ".boris-init-probe" });
    defer gpa.free(probe_dist);

    errdefer Io.Dir.cwd().deleteTree(io, probe_dist) catch {};
    const stats = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content_root,
        .dist_dir = probe_dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    Io.Dir.cwd().deleteTree(io, probe_dist) catch {};
    return .{ .verified = stats.pages_written };
}

pub fn run(io: Io, gpa: std.mem.Allocator, target_dir: []const u8, quiet: bool) u8 {
    const message = materialize(io, gpa, target_dir) catch |err| {
        std.debug.print("error: boris init failed: {s}\n", .{@errorName(err)});
        return @intFromEnum(ExitCode.io_error);
    };
    if (message.len > 0) {
        std.debug.print("error: {s}\n", .{message});
        gpa.free(message);
        return @intFromEnum(ExitCode.usage);
    }

    // Self-verify before claiming success. The starter tree is fixed, so a
    // probe failure means the binary and its starter templates disagree —
    // never ship that silently. Remove the whole tree (it was empty before
    // `init` ran) so exit 0 keeps meaning "materialized AND compiled".
    const outcome = verifyStarter(io, gpa, target_dir) catch |err| {
        Io.Dir.cwd().deleteTree(io, target_dir) catch {};
        std.debug.print(
            "error: the starter tree failed to compile ({s}); the target directory was removed — this is a compiler/starter drift bug, please report it\n",
            .{@errorName(err)},
        );
        return @intFromEnum(ExitCode.content_error);
    };

    if (!quiet) {
        std.debug.print(
            \\ok: initialized a Boris site in {s}
            \\  content/index.md                  trunk page
            \\  content/guides/getting-started.md satellite page
            \\  content/guides/publishing.md      satellite page with a relation
            \\  themes/boris/                     starter theme (closed layout slots, search UI)
            \\  boris.json                        publication profile (GitHub Pages)
            \\  standard-site.json                Atmosphere profile (replace the fake DID/URL)
            \\
            \\
        , .{target_dir});
        switch (outcome) {
            .verified => |pages| std.debug.print(
                "verified: starter compiled {d} page(s)\n\n",
                .{pages},
            ),
            .skipped => std.debug.print(
                "note: target directory resolves outside the workspace; skipped the starter compile probe\n\n",
                .{},
            ),
        }
        std.debug.print(
            \\next steps:
            \\  boris --input content --html-dir dist --theme themes/boris     build the site
            \\  boris check                                                    graph-health report
            \\  boris impact guides/getting-started                            dependency impact report
            \\  boris --context --quiet                                        AI Context Bundle
            \\  boris plan --profile boris.json                                inspect the plan
            \\  boris standard-site plan --profile standard-site.json          inspect Atmosphere records
            \\  boris watch --input content --html-dir dist --theme themes/boris   rebuild on change
            \\
            \\conventions:
            \\  search works out of the box: the theme ships the client for dist/_boris/search/search-index.json
            \\  shared fragments live under content/includes/ and never compile as pages
            \\  page images live in <stem>.assets/ beside the page that owns them
            \\
        , .{});
    }
    return @intFromEnum(ExitCode.success);
}

test "starter layout marks the search extraction root" {
    const marker = "<main class=\"site-body\" data-boris-search-root>";
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, starter_layout, idx, marker)) |at| {
        count += 1;
        idx = at + marker.len;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "starter layout carries the search client seams" {
    // These strings are the browser/compiler seam from the rendered-search
    // contract and the hooks the embedded client queries. If the starter and
    // the repo theme's search UI ever drift apart, this test names what went
    // missing instead of leaving a starter site with silent search.
    const layout_markers = [_][]const u8{
        "data-boris-search-ui",
        "data-boris-search-form",
        "data-boris-search-status",
        "data-boris-search-results",
        "_boris/search/search-index.json",
        "<noscript>",
        // The Standard.site contract requires the init reference layout to
        // include the closed {{head}} slot.
        "{{head}}",
    };
    for (layout_markers) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, starter_layout, marker) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, starter_layout, "data-boris-search-exclude") != null);
    try std.testing.expect(std.mem.indexOf(u8, starter_css, ".site-search") != null);
}

test "materialized starter compiles and the probe cleans up after itself" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const refused = try materialize(io, gpa, root);
    defer if (refused.len > 0) gpa.free(refused);
    try std.testing.expectEqual(@as(usize, 0), refused.len);

    // The production probe path: the fixed starter tree must compile, and the
    // probe output must be gone again afterwards.
    const outcome = try verifyStarter(io, gpa, root);
    try std.testing.expectEqual(@as(usize, 3), outcome.verified);

    const probe_dist = try std.fmt.allocPrint(gpa, "{s}/.boris-init-probe", .{root});
    defer gpa.free(probe_dist);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openDir(io, probe_dist, .{}));

    // The black-box script inits with an absolute target inside the
    // workspace; the probe must still find clean relative layout paths there.
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const abs_root = try std.fs.path.resolve(gpa, &.{ cwd, root });
    defer gpa.free(abs_root);
    const abs_outcome = try verifyStarter(io, gpa, abs_root);
    try std.testing.expectEqual(@as(usize, 3), abs_outcome.verified);

    // A target outside the workspace cannot host the probe (the containment
    // rule every generated output obeys); it must be skipped, not failed.
    const outside = try std.fs.path.resolve(gpa, &.{ cwd, "../../boris-init-outside" });
    defer gpa.free(outside);
    const skip = try verifyStarter(io, gpa, outside);
    try std.testing.expect(skip == .skipped);

    // One real compile to lock the rendered seams: the search index artifact
    // exists and a rendered page carries the search UI from the starter theme.
    const content_root = try std.fmt.allocPrint(gpa, "{s}/content", .{root});
    defer gpa.free(content_root);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/themes/boris/layouts/main.html", .{root});
    defer gpa.free(layout_path);
    const dist = try std.fmt.allocPrint(gpa, "{s}/.init-test-dist", .{root});
    defer gpa.free(dist);
    _ = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content_root,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    var dist_dir = try Io.Dir.cwd().openDir(io, dist, .{});
    defer dist_dir.close(io);
    _ = try dist_dir.statFile(io, "_boris/search/search-index.json", .{});
    const index_html = blk: {
        var file = try dist_dir.openFile(io, "index.html", .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        break :blk try reader.interface.allocRemaining(gpa, .unlimited);
    };
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "data-boris-search-ui") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "_boris/search/search-index.json") != null);
}
