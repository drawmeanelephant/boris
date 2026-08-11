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
const publication_location = @import("publication_location.zig");
const route_resolver = @import("route_resolver.zig");

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
pub const Options = struct {
    /// When present, root-relative and same-origin absolute URLs are checked
    /// against the declared publication origin/base path before route audit.
    publication_location: ?*const publication_location.Location = null,
    /// When set, counts each local (non-ignored) reference resolved by the
    /// audit — the audit's per-reference hot path. Never used for decisions.
    resolution_counter: ?*u64 = null,
    /// When set, counts common references resolved in caller-owned scratch
    /// storage. Never used for decisions.
    fast_path_counter: ?*u64 = null,
    /// Opt out of failing the build on a local Markdown destination the
    /// pre-Apex rewriter deliberately left literal.
    ///
    /// `docs/contracts/documentation-links.md` guarantees that a recognized
    /// Markdown destination with no graph target stays byte-for-byte unchanged.
    /// This audit is new and fatal, so a pinned site that relies on that skip
    /// cannot upgrade without a way to keep it. When set, a local reference whose
    /// resolved output path carries a Markdown extension is not reported as a
    /// missing route.
    ///
    /// Scope is deliberately narrow. It suppresses only `EROUTEMISSING`, never
    /// `EROUTEESCAPE`: escape is detected lexically because an existence check
    /// cannot see it, so a `.md` target that climbs above the output root is
    /// still refused. And it covers exactly the extensions the rewriter
    /// recognizes (`doclink.zig`), so it cannot be widened by accident into a
    /// general "ignore missing links" switch.
    allow_markdown_literals: bool = false,
};

/// Attributes whose value is a single URL. `srcset` is deliberately excluded:
/// it holds a comma-separated candidate list with descriptors and needs its own
/// grammar rather than being treated as one URL.
const url_attributes = [_][]const u8{ "href", "src" };

/// True when the target carries any URI scheme, is protocol-relative, is empty,
/// or is a same-document fragment. A generic scheme test is used rather than an
/// allowlist so `ftp:`, `blob:`, `urn:`, and future schemes are not mistaken for
/// local paths. Grammar: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":".
fn isIgnoredTarget(target: []const u8) bool {
    return route_resolver.isExternalOrEmpty(target) or target[0] == '#';
}

fn isSameDocumentTarget(target: []const u8) bool {
    return target.len == 0 or target[0] == '#';
}

fn shouldSkipTarget(target: []const u8, has_effective_base: bool) bool {
    return isIgnoredTarget(target) and !(has_effective_base and isSameDocumentTarget(target));
}

fn hasRelToken(value: []const u8, wanted: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (it.next()) |token| if (std.ascii.eqlIgnoreCase(token, wanted)) return true;
    return false;
}

/// Canonical/public metadata is a Boris-owned URL even when it is written in
/// a custom layout. Ordinary absolute links and CDN assets remain external
/// links and are not forced onto the site's own origin. `itemprop="url"` is
/// deliberately excluded: without the surrounding microdata item, it may
/// describe a nested entity rather than the document being published.
fn requiresPublicLocation(tag_name: []const u8, tag: []const u8, attribute: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(tag_name, "base") and std.ascii.eqlIgnoreCase(attribute, "href")) return true;
    if (std.ascii.eqlIgnoreCase(tag_name, "link") and
        std.ascii.eqlIgnoreCase(attribute, "href"))
    {
        return hasRelToken(html_scan.attrValue(tag, "rel") orelse "", "canonical");
    }
    if (std.ascii.eqlIgnoreCase(tag_name, "meta") and
        std.ascii.eqlIgnoreCase(attribute, "content"))
    {
        const property = html_scan.attrValue(tag, "property") orelse html_scan.attrValue(tag, "name") orelse return false;
        return std.ascii.eqlIgnoreCase(property, "og:url") or
            std.ascii.eqlIgnoreCase(property, "twitter:url") or
            std.ascii.eqlIgnoreCase(property, "url");
    }
    return false;
}

const BaseResolution = union(enum) {
    /// Target-relative synthetic document path used as the resolver base. A
    /// directory URL is represented by its index document so the existing
    /// resolver uses that directory for later relative references.
    local: []u8,
    /// Relative references after an external `<base>` do not target Boris's
    /// output manifest.
    external,
    /// The base cannot describe a usable local publication location.
    invalid,
};

fn baseSourceFromRoute(gpa: std.mem.Allocator, route: []const u8) ![]u8 {
    const without_fragment = route_resolver.stripFragment(route);
    const path = route_resolver.stripQuery(without_fragment);
    const relative = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (relative.len == 0) return gpa.dupe(u8, "index.html");
    if (std.mem.endsWith(u8, relative, "/")) return std.fmt.allocPrint(gpa, "{s}index.html", .{relative});
    return gpa.dupe(u8, relative);
}

fn resolveBase(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    target: []const u8,
    opts: Options,
) !BaseResolution {
    if (opts.publication_location) |location| {
        const classification = publication_location.classify(gpa, location, target, true) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAbsoluteUrl,
            error.OriginMismatch,
            error.BasePathMismatch,
            error.SiteUrlMismatch,
            => return .invalid,
        };
        switch (classification) {
            .external => return .external,
            .publication => |route| {
                defer gpa.free(route);
                return .{ .local = try baseSourceFromRoute(gpa, route) };
            },
            .relative => {},
        }
    } else if (target.len > 0 and target[0] != '#' and isIgnoredTarget(target)) {
        return .external;
    }

    const resolution = try resolveWithinRoot(gpa, source_path, target);
    return switch (resolution) {
        .escapes_root => .invalid,
        .path => |path| .{ .local = path },
    };
}

pub const Resolution = route_resolver.Resolution;
pub const resolveWithinRoot = route_resolver.resolveWithinRoot;

/// Newline counter for finding locations.
///
/// Line numbers are needed only for a finding that is actually emitted, and the
/// document scan visits tags in strictly increasing buffer order, so the count
/// is carried forward from the previous request instead of being recomputed from
/// the start of the buffer. Computing it eagerly for every reference made the
/// audit O(n²) in per-page link count: a page of 20,000 plain links spent all
/// of its time re-counting newlines it had already counted. On-demand plus
/// incremental means a clean page counts no newlines at all, and a page with
/// findings counts each byte at most once.
const LineCounter = struct {
    html: []const u8,
    cursor: usize = 0,
    line: u32 = 1,

    fn at(self: *LineCounter, offset: usize) u32 {
        const target = @min(offset, self.html.len);
        // The scan is monotonic, so this never fires today. It is here because a
        // stale carried count would be a silently wrong diagnostic rather than a
        // visible failure, and a rescan is cheaper than that risk.
        if (target < self.cursor) {
            self.cursor = 0;
            self.line = 1;
        }
        for (self.html[self.cursor..target]) |c| {
            if (c == '\n') self.line += 1;
        }
        self.cursor = target;
        return self.line;
    }
};

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
    return auditDocumentWithOptions(gpa, intended, source_path, html, .{}, findings);
}

fn appendPublicationFinding(
    gpa: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    source_path: []const u8,
    target: []const u8,
    line: u32,
    attribute: []const u8,
) !void {
    try appendFinding(gpa, findings, .EPUBLICATIONLOCATION, source_path, target, line, attribute);
}

/// Extensions the pre-Apex rewriter recognizes as Markdown destinations. Kept in
/// step with `doclink.zig`: the opt-out must cover exactly the class the rewriter
/// may leave literal, and nothing wider.
fn hasMarkdownExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx");
}

fn auditOne(
    gpa: std.mem.Allocator,
    intended: *const std.StringHashMapUnmanaged(void),
    source_path: []const u8,
    resolution_source_path: []const u8,
    has_effective_base: bool,
    tag_name: []const u8,
    tag: []const u8,
    target: []const u8,
    attribute: []const u8,
    opts: Options,
    findings: *std.ArrayList(Finding),
    /// Buffer offset of the tag carrying the reference. Resolved to a line number
    /// only when a finding is emitted.
    offset: usize,
    lines: *LineCounter,
) !void {
    if (isSameDocumentTarget(target) and !has_effective_base) return;

    var route_target: []const u8 = target;
    var owned_route: ?[]u8 = null;
    defer if (owned_route) |route| gpa.free(route);
    if (opts.publication_location) |location| {
        const require_public = requiresPublicLocation(tag_name, tag, attribute);
        const classification = publication_location.classify(gpa, location, target, require_public) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAbsoluteUrl,
            error.OriginMismatch,
            error.BasePathMismatch,
            error.SiteUrlMismatch,
            => {
                try appendPublicationFinding(gpa, findings, source_path, target, lines.at(offset), attribute);
                return;
            },
        };
        switch (classification) {
            .relative => {},
            .external => return,
            .publication => |route| {
                owned_route = route;
                route_target = route;
            },
        }
    } else if (shouldSkipTarget(route_target, has_effective_base)) {
        return;
    }

    if (shouldSkipTarget(route_target, has_effective_base)) return;
    // Every reference that reaches resolution is a local reference actually
    // resolved by the audit — the per-reference hot path (observational only).
    if (opts.resolution_counter) |counter| counter.* += 1;

    var fast_path_buffer: [route_resolver.fast_path_buffer_bytes]u8 = undefined;
    if (route_resolver.tryResolveFastPath(resolution_source_path, route_target, fast_path_buffer[0..])) |resolved| {
        if (opts.fast_path_counter) |counter| counter.* += 1;
        if (!intended.contains(resolved)) {
            if (!(opts.allow_markdown_literals and hasMarkdownExtension(resolved))) {
                try appendFinding(gpa, findings, .EROUTEMISSING, source_path, target, lines.at(offset), attribute);
            }
        }
        return;
    }

    const resolution = try resolveWithinRoot(gpa, resolution_source_path, route_target);
    switch (resolution) {
        .escapes_root => try appendFinding(gpa, findings, .EROUTEESCAPE, source_path, target, lines.at(offset), attribute),
        .path => |resolved| {
            defer gpa.free(resolved);
            if (intended.contains(resolved)) return;
            if (opts.allow_markdown_literals and hasMarkdownExtension(resolved)) return;
            try appendFinding(gpa, findings, .EROUTEMISSING, source_path, target, lines.at(offset), attribute);
        },
    }
}

fn auditDocumentWithOptions(
    gpa: std.mem.Allocator,
    intended: *const std.StringHashMapUnmanaged(void),
    source_path: []const u8,
    html: []const u8,
    opts: Options,
    findings: *std.ArrayList(Finding),
) !void {
    var i: usize = 0;
    var raw_text_depth: usize = 0;
    var saw_base = false;
    var external_base = false;
    var base_source_path: ?[]u8 = null;
    defer if (base_source_path) |path| gpa.free(path);
    var lines: LineCounter = .{ .html = html };
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
        if (std.ascii.eqlIgnoreCase(tag.name, "base")) {
            if (!tag.closing and !saw_base) {
                if (html_scan.attrValue(slice, "href")) |base_href| {
                    saw_base = true;
                    switch (try resolveBase(gpa, source_path, base_href, opts)) {
                        .local => |path| base_source_path = path,
                        .external => external_base = true,
                        .invalid => {
                            if (opts.publication_location != null) {
                                try appendPublicationFinding(gpa, findings, source_path, base_href, lines.at(i), "href");
                            } else {
                                try appendFinding(gpa, findings, .EROUTEESCAPE, source_path, base_href, lines.at(i), "href");
                            }
                        },
                    }
                }
            }
            // `<base>` establishes a URL context; it is not itself an output
            // artifact that the manifest must contain.
            continue;
        }
        if (external_base) continue;
        const resolution_source_path = base_source_path orelse source_path;
        const has_effective_base = base_source_path != null;
        for (url_attributes) |attribute| {
            const target = html_scan.attrValue(slice, attribute) orelse continue;
            try auditOne(gpa, intended, source_path, resolution_source_path, has_effective_base, tag.name, slice, target, attribute, opts, findings, i, &lines);
        }
        if (std.ascii.eqlIgnoreCase(tag.name, "meta")) {
            const target = html_scan.attrValue(slice, "content") orelse continue;
            if (requiresPublicLocation(tag.name, slice, "content")) {
                try auditOne(gpa, intended, source_path, resolution_source_path, has_effective_base, tag.name, slice, target, "content", opts, findings, i, &lines);
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
        try auditDocumentWithOptions(gpa, &intended, path, html, opts, findings);
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
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{}, &findings);
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
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{}, &findings);
    try std.testing.expectEqual(@as(usize, 4), findings.items.len);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[0].code);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[1].code);
    try std.testing.expectEqual(diag.Code.EROUTEESCAPE, findings.items[2].code);
    try std.testing.expectEqual(diag.Code.EROUTEESCAPE, findings.items[3].code);
}

test "a local Markdown destination without a published route is rejected" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "guides/start.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    // The pre-Apex rewriter may leave a missing `.md` target literal, but the
    // publication audit still rejects the route the output site cannot serve.
    try auditDocumentWithOptions(gpa, &intended, "guides/start.html", "<a href=\"../reference.md?raw=true#anchor\">x</a>", .{}, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[0].code);
    // A missing `.html` sibling is caught by the same manifest check.
    try auditDocumentWithOptions(gpa, &intended, "guides/start.html", "<a href=\"../reference.html\">x</a>", .{}, &findings);
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[1].code);
}

test "the markdown opt-out spares rewriter-left literals and nothing else" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "guides/start.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    const opts = Options{ .allow_markdown_literals = true };
    // The same `.md` and `.mdx` literals the default rejects are accepted, so a
    // site pinned to the pre-audit behaviour can upgrade.
    try auditDocumentWithOptions(gpa, &intended, "guides/start.html", "<a href=\"../reference.md?raw=true#anchor\">x</a>", opts, &findings);
    try auditDocumentWithOptions(gpa, &intended, "guides/start.html", "<a href=\"notes.mdx\">x</a>", opts, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);

    // The opt-out is not a general "ignore missing links" switch: a missing
    // `.html` route still fails, and traversal above the output root is still
    // refused even when the target is Markdown, because escape cannot be
    // established by existence.
    try auditDocumentWithOptions(gpa, &intended, "guides/start.html", "<a href=\"../reference.html\">x</a>", opts, &findings);
    try auditDocumentWithOptions(gpa, &intended, "guides/start.html", "<a href=\"../../outside.md\">x</a>", opts, &findings);
    try auditDocumentWithOptions(gpa, &intended, "guides/start.html", "<a href=\"readme.markdown\">x</a>", opts, &findings);
    try std.testing.expectEqual(@as(usize, 3), findings.items.len);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[0].code);
    try std.testing.expectEqual(diag.Code.EROUTEESCAPE, findings.items[1].code);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[2].code);
}

test "finding line numbers survive the incremental counter" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});
    try intended.put(gpa, "ok.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    // Findings at the first line, after clean lines, twice on one line, inside a
    // tag that spans lines, after CRLF, and on the last line. The counter is
    // carried forward across the whole scan, so a mistake in it would land here
    // as a wrong line rather than as a failure elsewhere.
    const html =
        "<a href=\"a.html\">1</a>\n" ++ // line 1
        "<a href=\"ok.html\">clean</a>\n" ++ // line 2, no finding
        "\n\n" ++ // lines 3-4 blank
        "<a href=\"b.html\">5</a><a href=\"c.html\">5</a>\n" ++ // line 5, twice
        "<a\n  href=\"d.html\"\n>6</a>\r\n" ++ // tag opens on line 6
        "\r\n" ++ // line 9
        "<img src=\"e.png\">"; // line 10, last line, unterminated by newline
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{}, &findings);

    const want = [_]struct { target: []const u8, line: u32 }{
        .{ .target = "a.html", .line = 1 },
        .{ .target = "b.html", .line = 5 },
        .{ .target = "c.html", .line = 5 },
        .{ .target = "d.html", .line = 6 },
        .{ .target = "e.png", .line = 10 },
    };
    try std.testing.expectEqual(want.len, findings.items.len);
    for (want, findings.items) |w, f| {
        try std.testing.expectEqualStrings(w.target, f.target);
        try std.testing.expectEqual(w.line, f.line);
    }
}

test "the line counter carries forward and recovers from a backwards offset" {
    const html = "a\nbb\nccc\ndddd";
    var lines: LineCounter = .{ .html = html };
    try std.testing.expectEqual(@as(u32, 1), lines.at(0));
    try std.testing.expectEqual(@as(u32, 1), lines.at(1));
    try std.testing.expectEqual(@as(u32, 2), lines.at(2));
    try std.testing.expectEqual(@as(u32, 3), lines.at(5));
    try std.testing.expectEqual(@as(u32, 4), lines.at(9));
    // An offset past the end is clamped rather than reading out of bounds.
    try std.testing.expectEqual(@as(u32, 4), lines.at(html.len + 100));
    // A backwards request must recount instead of reporting the carried line.
    try std.testing.expectEqual(@as(u32, 2), lines.at(3));
    try std.testing.expectEqual(@as(u32, 4), lines.at(html.len));
}

test "same-document references without a base remain ignored" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    try auditDocument(gpa, &intended, "index.html", "<a href=\"#missing\">fragment</a><a href=\"\">empty</a>", &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a local base makes fragment-only and empty references audit its document route" {
    const gpa = std.testing.allocator;
    const github_pages = @import("github_pages.zig");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);

    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});
    try intended.put(gpa, "guides/index.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    const html = "<base href=\"/boris/guides/\"><a href=\"#top\">fragment</a><a href=\"\">empty</a>";
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{ .publication_location = &location }, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a base makes missing fragment-only and empty references report the base document" {
    const gpa = std.testing.allocator;
    const github_pages = @import("github_pages.zig");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);

    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    const html = "<base href=\"/boris/guides/\"><a href=\"#top\">fragment</a><a href=\"\">empty</a>";
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{ .publication_location = &location }, &findings);
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
    for (findings.items) |finding| try std.testing.expectEqual(diag.Code.EROUTEMISSING, finding.code);
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

    try auditDocumentWithOptions(gpa, &intended, "index.html", "<a href=\"old.html\">stale</a>", .{}, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(diag.Code.EROUTEMISSING, findings.items[0].code);
}

test "project-site root-relative links must carry the publication base path" {
    const gpa = std.testing.allocator;
    const github_pages = @import("github_pages.zig");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});
    try intended.put(gpa, "assets/theme.css", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    try auditDocumentWithOptions(gpa, &intended, "index.html", "<a href=\"/boris/assets/theme.css\">ok</a><a href=\"/assets/theme.css\">bad</a>", .{ .publication_location = &location }, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(diag.Code.EPUBLICATIONLOCATION, findings.items[0].code);
    try std.testing.expectEqualStrings("/assets/theme.css", findings.items[0].target);
}

test "canonical and public metadata must match the declared origin" {
    const gpa = std.testing.allocator;
    const github_pages = @import("github_pages.zig");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    const html = "<link rel=\"canonical\" href=\"https://wrong.example/docs\"><meta property=\"og:url\" content=\"https://wrong.example/docs\">";
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{ .publication_location = &location }, &findings);
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
    for (findings.items) |finding| try std.testing.expectEqual(diag.Code.EPUBLICATIONLOCATION, finding.code);
}

test "the first effective base controls relative and query-only routes" {
    const gpa = std.testing.allocator;
    const github_pages = @import("github_pages.zig");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);

    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});
    try intended.put(gpa, "next.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    const html =
        "<base href=\"/boris/\"><base href=\"/boris/guides/\">" ++
        "<a href=\"next.html\">next</a><a href=\"?view=all\">same base</a>";
    try auditDocumentWithOptions(gpa, &intended, "guides/start.html", html, .{ .publication_location = &location }, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a base route is context, not an artifact, and browser-relative routes use it" {
    const gpa = std.testing.allocator;
    const github_pages = @import("github_pages.zig");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);

    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "guides/next.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    const html = "<base href=\"/boris/guides/\"><a href=\"next.html\">next</a>";
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{ .publication_location = &location }, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a hosted base with the wrong origin or path fails publication validation" {
    const gpa = std.testing.allocator;
    const github_pages = @import("github_pages.zig");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);

    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "next.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    const html = "<base href=\"https://wrong.example/docs/\"><a href=\"next.html\">next</a>";
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{ .publication_location = &location }, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(diag.Code.EPUBLICATIONLOCATION, findings.items[0].code);
    try std.testing.expectEqualStrings("https://wrong.example/docs/", findings.items[0].target);
}

test "ambiguous microdata url is not assumed to be the document URL" {
    const gpa = std.testing.allocator;
    const github_pages = @import("github_pages.zig");
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);

    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);
    const html = "<meta itemprop=\"url\" content=\"https://other.example/entity\">";
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{ .publication_location = &location }, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "resolution counter counts resolved local references" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});
    try intended.put(gpa, "real.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    var resolved: u64 = 0;
    var fast_path: u64 = 0;
    const html =
        "<a href=\"real.html\">ok</a>" ++
        "<a href=\"https://example.com/x\">external</a>" ++
        "<a href=\"#top\">fragment</a>" ++
        "<a href=\"missing.html\">x</a>";
    try auditDocumentWithOptions(gpa, &intended, "index.html", html, .{
        .resolution_counter = &resolved,
        .fast_path_counter = &fast_path,
    }, &findings);
    // External and same-document fragment targets are skipped, not resolved.
    try std.testing.expectEqual(@as(u64, 2), resolved);
    try std.testing.expectEqual(@as(u64, 2), fast_path);
}

test "common audit routes use caller scratch without allocation" {
    const gpa = std.testing.allocator;
    var intended: std.StringHashMapUnmanaged(void) = .{};
    defer intended.deinit(gpa);
    try intended.put(gpa, "index.html", {});
    try intended.put(gpa, "real.html", {});

    var findings: std.ArrayList(Finding) = .empty;
    defer freeFindings(gpa, &findings);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try auditDocumentWithOptions(
        failing.allocator(),
        &intended,
        "index.html",
        "<a href=\"real.html\">ok</a>",
        .{},
        &findings,
    );
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}
