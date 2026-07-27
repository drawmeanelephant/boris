//! Post-render audit of local links in the staged/live HTML overlay.
//!
//! Runs against the complete live page set immediately before the staged tree
//! is renamed into the published output directory, so a local reference the
//! published site could not serve never reaches published output.
//!
//! This is deliberately separate from `doclink.zig`. That module rewrites
//! recognized inline Markdown link destinations before Apex and, per
//! `docs/contracts/documentation-links.md`, leaves missing targets byte-for-byte
//! unchanged. Nothing here rewrites anything: it inspects generated HTML and
//! reports what the published site would actually serve. The rewrite boundary
//! is unchanged; this adds an output gate underneath it.
//!
//! Two properties are load-bearing:
//!
//! 1. **Resolution is set membership against the intended output manifest, not
//!    a filesystem probe.** A file that merely happens to exist in the live
//!    directory may be deleted by this build's stale cleanup, so treating it as
//!    proof of a working link publishes a break. Statting also cannot tell a
//!    directory from a page and costs a syscall per reference.
//! 2. **Escape is detected lexically, before any path is used.** A target such
//!    as `../docs/x.png` can resolve to a real file beside the output directory
//!    on the build machine while 404ing on a deployed host, so an
//!    existence-based check would call it healthy.

const std = @import("std");
const diag = @import("diag.zig");
const html_scan = @import("html_scan.zig");

pub const Finding = struct {
    code: diag.Code,
    /// Output-relative path of the page that carries the reference.
    source: []const u8,
    /// Raw attribute value, exactly as published.
    target: []const u8,
    line: u32,
    /// Attribute the reference was found in, e.g. `href` or `src`.
    attribute: []const u8,
};

/// Fragment (`#anchor`) checking is deliberately NOT implemented here. Doing it
/// correctly requires parsing real `id` attributes rather than string-matching
/// them, URL-decoding the fragment, and handling same-document references — and
/// a fragment check that fails open on an unreadable target is worse than none,
/// because it reports success it did not establish. Route checking stands alone
/// until that is built. `EFRAGMENTMISSING` is reserved in the diagnostics
/// contract for it.
pub const Options = struct {};

/// Attributes whose value is a single URL. `srcset` is deliberately excluded:
/// it holds a comma-separated candidate list with descriptors and needs its own
/// grammar rather than being treated as one URL.
const url_attributes = [_][]const u8{ "href", "src" };

/// Maximum percent-decoding passes. Decoding to stability defeats multiply
/// encoded traversal such as `%252e%252e`; the bound stops a decoding loop.
const max_decode_passes = 4;

/// True when the target carries any URI scheme, is protocol-relative, is empty,
/// or is a same-document fragment. A generic scheme test is used rather than an
/// allowlist so `ftp:`, `blob:`, `urn:`, and future schemes are not mistaken for
/// local paths. Grammar: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":".
fn isIgnoredTarget(target: []const u8) bool {
    if (target.len == 0 or target[0] == '#') return true;
    if (std.mem.startsWith(u8, target, "//")) return true;
    if (!std.ascii.isAlphabetic(target[0])) return false;
    for (target, 0..) |c, i| {
        if (c == ':') return i > 0;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return false;
}

/// True for a Markdown destination the link rewriter deliberately left alone.
///
/// `docs/contracts/documentation-links.md` lists "missing graph targets" under
/// **Unchanged inputs**: a `.md`/`.mdx` link whose target is not a graph node
/// stays byte-for-byte literal by design, and a golden fixture pins that. This
/// audit therefore does not judge those references. Whether a literal `.md`
/// href should remain publishable at all is a question for that contract, not
/// something to decide by making the build fail here.
fn isUnrewrittenMarkdownTarget(target: []const u8) bool {
    const path = stripQuery(stripFragment(target));
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx");
}

fn stripFragment(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '#')) |i| return target[0..i];
    return target;
}

fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

/// Percent-decode to stability and normalize backslashes to `/`. Widening what
/// counts as a separator can only cause a reference to be reported, never to be
/// silently accepted, which is the safe direction for a publication gate.
fn decodeToStability(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var current = try gpa.dupe(u8, raw);
    errdefer gpa.free(current);
    var pass: usize = 0;
    while (pass < max_decode_passes) : (pass += 1) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        var changed = false;
        while (i < current.len) {
            if (current[i] == '%' and i + 2 < current.len) {
                const hi = std.fmt.charToDigit(current[i + 1], 16) catch {
                    try out.append(gpa, current[i]);
                    i += 1;
                    continue;
                };
                const lo = std.fmt.charToDigit(current[i + 2], 16) catch {
                    try out.append(gpa, current[i]);
                    i += 1;
                    continue;
                };
                const byte = @as(u8, hi) * 16 + @as(u8, lo);
                try out.append(gpa, if (byte == '\\') '/' else byte);
                i += 3;
                changed = true;
                continue;
            }
            try out.append(gpa, if (current[i] == '\\') '/' else current[i]);
            i += 1;
        }
        const next = try out.toOwnedSlice(gpa);
        gpa.free(current);
        current = next;
        if (!changed) break;
    }
    return current;
}

pub const Resolution = union(enum) {
    /// Output-root-relative path the browser would request.
    path: []u8,
    /// Target climbs above the output root and can never be served.
    escapes_root,
};

/// Resolve `target` against `source` using URL-reference semantics, refusing any
/// result that leaves the output root.
pub fn resolveWithinRoot(
    gpa: std.mem.Allocator,
    source: []const u8,
    target: []const u8,
) !Resolution {
    // A query-only or fragment-only reference addresses the source document.
    const no_fragment = stripFragment(target);
    if (no_fragment.len == 0 or no_fragment[0] == '?') return .{ .path = try gpa.dupe(u8, source) };

    const decoded = try decodeToStability(gpa, stripQuery(no_fragment));
    defer gpa.free(decoded);

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(gpa);

    if (!std.mem.startsWith(u8, decoded, "/")) {
        if (std.fs.path.dirnamePosix(source)) |dir| {
            var it = std.mem.splitScalar(u8, dir, '/');
            while (it.next()) |seg| {
                if (seg.len != 0 and !std.mem.eql(u8, seg, ".")) try segments.append(gpa, seg);
            }
        }
    }

    // A trailing `/` and a trailing `.`/`..` segment independently mean the
    // reference names a directory. Tracked apart so that walking the segments
    // cannot clear the trailing-slash signal recorded before the walk.
    const trailing_slash = std.mem.endsWith(u8, decoded, "/");
    var ended_on_dot_segment = false;
    var it = std.mem.splitScalar(u8, decoded, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.eql(u8, seg, ".")) {
            ended_on_dot_segment = true;
            continue;
        }
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len == 0) return .escapes_root;
            _ = segments.pop();
            ended_on_dot_segment = true;
            continue;
        }
        ended_on_dot_segment = false;
        try segments.append(gpa, seg);
    }
    const directory_reference = trailing_slash or ended_on_dot_segment;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (segments.items, 0..) |seg, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, seg);
    }
    if (directory_reference or out.items.len == 0) {
        if (out.items.len > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, "index.html");
    }
    return .{ .path = try out.toOwnedSlice(gpa) };
}

fn lineNumber(html: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (html[0..@min(offset, html.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn appendFinding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    code: diag.Code,
    source: []const u8,
    target: []const u8,
    line: u32,
    attribute: []const u8,
) !void {
    const owned_source = try gpa.dupe(u8, source);
    errdefer gpa.free(owned_source);
    const owned_target = try gpa.dupe(u8, target);
    errdefer gpa.free(owned_target);
    try findings.append(gpa, .{
        .code = code,
        .source = owned_source,
        .target = owned_target,
        .line = line,
        .attribute = attribute,
    });
}

pub fn freeFindings(gpa: std.mem.Allocator, findings: *std.ArrayList(Finding)) void {
    for (findings.items) |f| {
        gpa.free(f.source);
        gpa.free(f.target);
    }
    findings.deinit(gpa);
}

/// Walk one page's tags and audit every URL-bearing attribute.
///
/// Tag-aware rather than substring-based: a reference inside a comment or a
/// raw-text element such as `<code>` is documentation, not a link. Boris's own
/// site documents HTML, so a substring scanner reports those as broken links.
pub fn auditDocument(
    gpa: std.mem.Allocator,
    intended: *const std.StringHashMapUnmanaged(void),
    source_path: []const u8,
    html: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var i: usize = 0;
    var raw_text_depth: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        const tag = html_scan.tagAt(html, i) orelse {
            i += 1;
            continue;
        };
        defer i = tag.end + 1;

        if (std.mem.eql(u8, tag.name, "!comment")) continue;
        if (html_scan.isRawTextElement(tag.name)) {
            if (tag.closing) {
                if (raw_text_depth > 0) raw_text_depth -= 1;
            } else if (!tag.self_closing) raw_text_depth += 1;
            continue;
        }
        if (raw_text_depth > 0 or tag.closing) continue;

        const slice = html[i .. tag.end + 1];
        for (url_attributes) |attribute| {
            const target = html_scan.attrValue(slice, attribute) orelse continue;
            if (isIgnoredTarget(target)) continue;
            if (isUnrewrittenMarkdownTarget(target)) continue;
            const resolution = try resolveWithinRoot(gpa, source_path, target);
            switch (resolution) {
                .escapes_root => try appendFinding(gpa, findings, .EROUTEESCAPE, source_path, target, lineNumber(html, i), attribute),
                .path => |resolved| {
                    defer gpa.free(resolved);
                    if (!intended.contains(resolved)) {
                        try appendFinding(gpa, findings, .EROUTEMISSING, source_path, target, lineNumber(html, i), attribute);
                    }
                },
            }
        }
    }
}

fn readOverlay(
    io: std.Io,
    staged_dir: std.Io.Dir,
    live_dir: std.Io.Dir,
    path: []const u8,
    gpa: std.mem.Allocator,
) ![]u8 {
    return readFile(io, staged_dir, path, gpa) catch |err| switch (err) {
        error.FileNotFound => readFile(io, live_dir, path, gpa),
        else => return err,
    };
}

fn readFile(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

/// Audit every live page in the staged/live overlay.
///
/// `page_paths` is the complete live PageDb output set, matching the overlay
/// rule used for the search artifact: a staged page wins when present, cached
/// pages are read from `live_dir`, and removed pages are excluded. Auditing the
/// staged directory alone would report every unchanged page as missing on an
/// incremental build.
///
/// `asset_paths` carries published non-page outputs so stylesheet and image
/// references resolve. Together these two lists are the manifest of outputs
/// intended to survive this build; nothing else counts as a valid target.
pub fn audit(
    io: std.Io,
    gpa: std.mem.Allocator,
    staged_dir: std.Io.Dir,
    live_dir: std.Io.Dir,
    page_paths: []const []const u8,
    asset_paths: []const []const u8,
    opts: Options,
    findings: *std.ArrayList(Finding),
) !void {
    _ = opts;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    for (page_paths) |p| try intended.put(gpa, p, {});
    for (asset_paths) |p| try intended.put(gpa, p, {});

    for (page_paths) |path| {
        if (!std.mem.endsWith(u8, path, ".html")) continue;
        const html = readOverlay(io, staged_dir, live_dir, path, gpa) catch |err| switch (err) {
            // A page this build intends to publish is absent from both the
            // staged and live trees. That is a build integrity failure, not a
            // clean page, so it is reported rather than skipped.
            error.FileNotFound => {
                try appendFinding(gpa, findings, .EROUTEMISSING, path, path, 0, "page");
                continue;
            },
            else => return err,
        };
        defer gpa.free(html);
        try auditDocument(gpa, &intended, path, html, findings);
    }
}

test "any scheme-bearing, protocol-relative, or fragment-only target is skipped" {
    try std.testing.expect(isIgnoredTarget("#top"));
    try std.testing.expect(isIgnoredTarget("https://example.com"));
    try std.testing.expect(isIgnoredTarget("HTTPS://example.com"));
    try std.testing.expect(isIgnoredTarget("//cdn.example.com/a.js"));
    try std.testing.expect(isIgnoredTarget("mailto:a@b.c"));
    // A hard-coded allowlist would have reported these as broken local paths.
    try std.testing.expect(isIgnoredTarget("ftp://example.com/f"));
    try std.testing.expect(isIgnoredTarget("blob:1234"));
    try std.testing.expect(isIgnoredTarget("urn:isbn:0451450523"));
    try std.testing.expect(!isIgnoredTarget("../missing.html"));
    try std.testing.expect(!isIgnoredTarget("assets/theme.css"));
    // A colon inside a path segment is not a scheme.
    try std.testing.expect(!isIgnoredTarget("weird/a:b.html"));
}

test "a target climbing above the output root is refused lexically" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try resolveWithinRoot(gpa, "index.html", "../docs/evidence/x.png")) == .escapes_root);
    try std.testing.expect((try resolveWithinRoot(gpa, "guides/overview.html", "../../etc/passwd")) == .escapes_root);
    // Single, double, and backslash-encoded traversal all reach the same refusal.
    try std.testing.expect((try resolveWithinRoot(gpa, "index.html", "%2e%2e/secret")) == .escapes_root);
    try std.testing.expect((try resolveWithinRoot(gpa, "index.html", "%252e%252e/secret")) == .escapes_root);
    try std.testing.expect((try resolveWithinRoot(gpa, "index.html", "..\\secret")) == .escapes_root);
    try std.testing.expect((try resolveWithinRoot(gpa, "index.html", "%2e%2e%5csecret")) == .escapes_root);
}

test "relative targets resolve against the linking page's directory" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { src: []const u8, target: []const u8, want: []const u8 }{
        .{ .src = "guides/overview.html", .target = "trunk-satellite.html", .want = "guides/trunk-satellite.html" },
        .{ .src = "guides/overview.html", .target = "../reference/commands.html", .want = "reference/commands.html" },
        .{ .src = "guides/overview.html", .target = "/assets/theme.css", .want = "assets/theme.css" },
        .{ .src = "index.html", .target = "reference/outputs.html?v=1#rag", .want = "reference/outputs.html" },
        // Directory-style references need an index document to be servable.
        .{ .src = "index.html", .target = "getting-started/", .want = "getting-started/index.html" },
        // A query-only or fragment-only reference addresses the source page.
        .{ .src = "guides/overview.html", .target = "?view=all", .want = "guides/overview.html" },
        .{ .src = "index.html", .target = ".", .want = "index.html" },
    };
    for (cases) |c| {
        const r = try resolveWithinRoot(gpa, c.src, c.target);
        defer gpa.free(r.path);
        try std.testing.expectEqualStrings(c.want, r.path);
    }
}

test "references inside code, pre, and comments are documentation, not links" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    // Every reference below is unresolvable, but none is a published link.
    const html =
        "<pre><code>&lt;a href=\"../escaped.png\"&gt;</code></pre>" ++
        "<code>href=\"missing.html\"</code>" ++
        "<!-- <a href=\"../commented.png\">x</a> -->" ++
        "<script>var s = 'href=\"../script.png\"';</script>" ++
        "<a data-href=\"../not-a-link.png\">safe</a>";
    try auditDocument(gpa, &intended, "index.html", html, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "published references are audited across quoting and attribute variants" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});
    try intended.put(gpa, "real.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    const html =
        "<a href=\"real.html\">ok</a>" ++ // resolves
        "<a href='missing.html'>x</a>" ++ // single-quoted, missing
        "<a HREF=\"gone.html\">x</a>" ++ // uppercase, missing
        "<img src=../outside.png>" ++ // unquoted, escapes root
        "<a href=\"../docs/evidence/x.png\">x</a>"; // escapes root
    try auditDocument(gpa, &intended, "index.html", html, &findings);

    try std.testing.expectEqual(@as(usize, 4), findings.items.len);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[0].code);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[1].code);
    try std.testing.expectEqual(diag.Code.EROUTEESCAPE, findings.items[2].code);
    try std.testing.expectEqual(diag.Code.EROUTEESCAPE, findings.items[3].code);
}

test "a deliberately unrewritten Markdown destination is left to its own contract" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "guides/start.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    // documentation-links.md keeps a missing `.md` target literal on purpose,
    // and a golden fixture pins it. This audit must not overrule that.
    try auditDocument(gpa, &intended, "guides/start.html", "<a href=\"../reference.md?raw=true#anchor\">x</a>", &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
    // A missing `.html` sibling is still caught.
    try auditDocument(gpa, &intended, "guides/start.html", "<a href=\"../reference.html\">x</a>", &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}

test "a file present in the live tree but not intended to survive is not a valid target" {
    const gpa = std.testing.allocator;
    // `old.html` exists on disk from a previous build and will be removed by
    // this build's stale cleanup. Set membership, not existence, decides.
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    try auditDocument(gpa, &intended, "index.html", "<a href=\"old.html\">stale</a>", &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[0].code);
}
