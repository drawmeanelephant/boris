//! `boris init`: materialize a deterministic starter site.
//!
//! Writes a small, comprehensible tree that builds and validates out of the
//! box: three Markdown pages exercising the graph (trunk, satellite, wiki
//! links, a semantic relation), a starter theme using the closed layout
//! slots, and a publication profile ready for `boris plan --profile`.
//!
//! The tree is byte-deterministic: every file is a fixed constant, so two
//! runs in identical conditions produce identical trees. `init` refuses to
//! touch an existing non-empty directory — no archaeology, and no silent
//! clobbering.

const std = @import("std");
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
    \\themes/boris/                 starter theme (closed layout slots)
    \\boris.json                    publication profile (GitHub Pages)
    \\standard-site.json            Atmosphere profile (edit the fake DID/URL)
    \\```
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

    if (!quiet) {
        std.debug.print(
            \\ok: initialized a Boris site in {s}
            \\  content/index.md                  trunk page
            \\  content/guides/getting-started.md satellite page
            \\  content/guides/publishing.md      satellite page with a relation
            \\  themes/boris/                     starter theme (closed layout slots)
            \\  boris.json                        publication profile (GitHub Pages)
            \\  standard-site.json                Atmosphere profile (replace the fake DID/URL)
            \\
            \\next steps:
            \\  boris --input content --html-dir dist --theme themes/boris     build the site
            \\  boris plan --profile boris.json                                inspect the plan
            \\  boris standard-site plan --profile standard-site.json          inspect Atmosphere records
            \\  boris watch --input content --html-dir dist --theme themes/boris   rebuild on change
            \\
            \\conventions:
            \\  shared fragments live under content/includes/ and never compile as pages
            \\  page images live in <stem>.assets/ beside the page that owns them
            \\
        , .{target_dir});
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
