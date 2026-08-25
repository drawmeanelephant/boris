//! Deterministic search indexing for already-rendered Boris HTML.

const std = @import("std");

pub const format = "boris-rendered-search-index";
pub const schema_version: u32 = 1;
pub const output_path = "_boris/search/search-index.json";

pub const Error = error{ MultipleSearchRoots, MissingSearchRoot };

pub const Section = struct { level: u8, heading: []const u8, fragment: []const u8, text: []const u8, code: []const u8 };
pub const Document = struct { path: []const u8, title: []const u8, sections: []const Section };
const MutableSection = struct { level: u8 = 0, heading: std.ArrayList(u8) = .empty, fragment: std.ArrayList(u8) = .empty, prose: std.ArrayList(u8) = .empty, code: std.ArrayList(u8) = .empty };
const html_scan = @import("html_scan.zig");
const json_out = @import("json_out.zig");
const Tag = html_scan.Tag;
const Range = html_scan.Range;
const tagAt = html_scan.tagAt;
const attrValue = html_scan.attrValue;
const hasAttr = html_scan.hasAttr;

const matchingRange = html_scan.matchingRange;

const ExtractRoot = struct {
    range: Range,
    /// True for an explicit marker, `<main>`, `<article>`, or `role="main"`.
    /// False for `<body>` / whole-document fallback, where layout chrome is skipped.
    declared: bool,
};

fn elementRange(html: []const u8, start: usize, name: []const u8) Error!Range {
    return matchingRange(html, start, name) orelse error.MissingSearchRoot;
}

fn findRoot(html: []const u8, require_marker: bool) Error!?ExtractRoot {
    var explicit: ?usize = null;
    var count: usize = 0;
    var first_main: ?usize = null;
    var first_article: ?usize = null;
    var first_role_main: ?usize = null;
    var first_body: ?usize = null;
    var i: usize = 0;
    while (i < html.len) {
        const start = std.mem.indexOfScalarPos(u8, html, i, '<') orelse break;
        const tag = tagAt(html, start) orelse {
            i = start + 1;
            continue;
        };
        if (!tag.closing and !tag.self_closing) {
            const t = html[start .. tag.end + 1];
            if (hasAttr(t, "data-boris-search-root")) {
                explicit = start;
                count += 1;
            } else if (first_main == null and std.ascii.eqlIgnoreCase(tag.name, "main")) {
                first_main = start;
            } else if (first_article == null and std.ascii.eqlIgnoreCase(tag.name, "article")) {
                first_article = start;
            } else if (first_role_main == null and std.ascii.eqlIgnoreCase(attrValue(t, "role") orelse "", "main")) {
                first_role_main = start;
            } else if (first_body == null and std.ascii.eqlIgnoreCase(tag.name, "body")) {
                first_body = start;
            }
        }
        i = tag.end + 1;
    }
    if (count > 1) return error.MultipleSearchRoots;
    if (explicit) |s| return .{ .range = try elementRange(html, s, "main"), .declared = true };
    if (require_marker) return error.MissingSearchRoot;
    if (first_main) |s| return .{ .range = try elementRange(html, s, "main"), .declared = true };
    if (first_article) |s| return .{ .range = try elementRange(html, s, "article"), .declared = true };
    if (first_role_main) |s| {
        const tag = tagAt(html, s) orelse return error.MissingSearchRoot;
        return .{ .range = try elementRange(html, s, tag.name), .declared = true };
    }
    if (first_body) |s| return .{ .range = try elementRange(html, s, "body"), .declared = false };
    return null;
}

fn isAlwaysExcludedName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "nav") or
        std.ascii.eqlIgnoreCase(name, "footer") or
        std.ascii.eqlIgnoreCase(name, "script") or
        std.ascii.eqlIgnoreCase(name, "style") or
        std.ascii.eqlIgnoreCase(name, "template") or
        std.ascii.eqlIgnoreCase(name, "noscript") or
        std.ascii.eqlIgnoreCase(name, "svg") or
        std.ascii.eqlIgnoreCase(name, "canvas");
}

fn isFallbackChromeName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "header") or std.ascii.eqlIgnoreCase(name, "aside");
}

fn isSearchExcludeMarker(txt: []const u8) bool {
    return hasAttr(txt, "data-boris-search-exclude") or
        hasAttr(txt, "data-boris-search-ignore") or
        hasAttr(txt, "data-boris-noindex");
}

fn isHidden(txt: []const u8) bool {
    return hasAttr(txt, "hidden") or
        hasAttr(txt, "inert") or
        std.mem.eql(u8, attrValue(txt, "aria-hidden") orelse "", "true");
}

fn opensElement(tag: Tag) bool {
    return !tag.closing and !tag.self_closing and !html_scan.isVoidElement(tag.name);
}

fn appendCodepoint(out: *std.ArrayList(u8), a: std.mem.Allocator, cp: u32) !void {
    if (cp <= 0x7f) return out.append(a, @intCast(cp));
    if (cp <= 0x7ff) {
        try out.append(a, @intCast(0xc0 | (cp >> 6)));
        return out.append(a, @intCast(0x80 | (cp & 0x3f)));
    }
    if (cp <= 0xffff) {
        try out.append(a, @intCast(0xe0 | (cp >> 12)));
        try out.append(a, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        return out.append(a, @intCast(0x80 | (cp & 0x3f)));
    }
    if (cp <= 0x10ffff) {
        try out.append(a, @intCast(0xf0 | (cp >> 18)));
        try out.append(a, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try out.append(a, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        return out.append(a, @intCast(0x80 | (cp & 0x3f)));
    }
}
fn appendEntity(out: *std.ArrayList(u8), a: std.mem.Allocator, e: []const u8) !bool {
    const pairs = .{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' }, .{ "nbsp", ' ' } };
    inline for (pairs) |p| if (std.mem.eql(u8, e, p[0])) {
        try out.append(a, p[1]);
        return true;
    };
    if (e.len > 1 and e[0] == '#') {
        var base: u8 = 10;
        var digits = e[1..];
        if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X')) {
            base = 16;
            digits = digits[1..];
        }
        const cp = std.fmt.parseInt(u32, digits, base) catch return false;
        try appendCodepoint(out, a, cp);
        return true;
    }
    return false;
}
fn appendDecoded(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') if (std.mem.indexOfScalarPos(u8, text, i + 1, ';')) |semi| if (try appendEntity(out, a, text[i + 1 .. semi])) {
            i = semi + 1;
            continue;
        };
        try out.append(a, text[i]);
        i += 1;
    }
}
fn normalize(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var space = false;
    for (raw) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) try out.append(a, ' ');
        space = false;
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}
fn isBlock(n: []const u8) bool {
    return std.ascii.eqlIgnoreCase(n, "p") or
        std.ascii.eqlIgnoreCase(n, "div") or
        std.ascii.eqlIgnoreCase(n, "li") or
        std.ascii.eqlIgnoreCase(n, "section") or
        std.ascii.eqlIgnoreCase(n, "article") or
        std.ascii.eqlIgnoreCase(n, "blockquote") or
        std.ascii.eqlIgnoreCase(n, "pre") or
        std.ascii.eqlIgnoreCase(n, "details") or
        std.ascii.eqlIgnoreCase(n, "summary") or
        std.ascii.eqlIgnoreCase(n, "table") or
        std.ascii.eqlIgnoreCase(n, "thead") or
        std.ascii.eqlIgnoreCase(n, "tbody") or
        std.ascii.eqlIgnoreCase(n, "tfoot") or
        std.ascii.eqlIgnoreCase(n, "tr") or
        std.ascii.eqlIgnoreCase(n, "td") or
        std.ascii.eqlIgnoreCase(n, "th");
}

fn isBreak(n: []const u8) bool {
    return std.ascii.eqlIgnoreCase(n, "br") or std.ascii.eqlIgnoreCase(n, "hr");
}

fn decodeNormalize(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(a);
    try appendDecoded(&decoded, a, raw);
    return normalize(a, decoded.items);
}
fn slugify(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var dash = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and out.items.len > 0) try out.append(a, '-');
            dash = false;
            try out.append(a, std.ascii.toLower(c));
        } else if (out.items.len > 0) dash = true;
    }
    return out.toOwnedSlice(a);
}

pub fn indexHtml(a: std.mem.Allocator, path: []const u8, html: []const u8, require_marker: bool) !Document {
    const found = try findRoot(html, require_marker) orelse ExtractRoot{
        .range = .{ .start = 0, .end = html.len },
        .declared = false,
    };
    const root = found.range;
    const exclude_chrome = !found.declared;
    var sections: std.ArrayList(MutableSection) = .empty;
    defer {
        for (sections.items) |*s| {
            s.heading.deinit(a);
            s.fragment.deinit(a);
            s.prose.deinit(a);
            s.code.deinit(a);
        }
        sections.deinit(a);
    }
    try sections.append(a, .{});
    var title: ?[]u8 = null;
    var heading: bool = false;
    var heading_marked = false;
    var code_depth: usize = 0;
    var excluded: usize = 0;
    var level: u8 = 0;
    var i = root.start;
    while (i < root.end) {
        if (html[i] != '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '<') orelse root.end;
            if (excluded == 0) {
                if (heading) try appendDecoded(&sections.items[sections.items.len - 1].heading, a, html[i..end]) else if (code_depth > 0) try appendDecoded(&sections.items[sections.items.len - 1].code, a, html[i..end]) else try appendDecoded(&sections.items[sections.items.len - 1].prose, a, html[i..end]);
            }
            i = end;
            continue;
        }
        const tag = tagAt(html, i) orelse {
            i += 1;
            continue;
        };
        const txt = html[i .. tag.end + 1];
        const n = tag.name;
        if (n[0] == '!') {
            i = tag.end + 1;
            continue;
        }
        const excluded_name = isAlwaysExcludedName(n) or
            (exclude_chrome and isFallbackChromeName(n)) or
            isSearchExcludeMarker(txt) or
            isHidden(txt);
        if (!tag.closing) {
            // Count every nested opener while excluded. Incrementing only on
            // the chrome tag itself let `</h2>` inside `<nav>`/`<aside>` drop
            // the depth to zero and index the remaining sidebar.
            if (excluded_name or excluded > 0) {
                if (opensElement(tag)) excluded += 1;
            }
            if (excluded == 0) {
                if (n.len == 2 and n[0] == 'h' and n[1] >= '1' and n[1] <= '6') {
                    try sections.append(a, .{ .level = n[1] - '0' });
                    heading = true;
                    heading_marked = attrValue(txt, "data-boris-search-title") != null;
                    level = n[1] - '0';
                    if (attrValue(txt, "id")) |id| try appendDecoded(&sections.items[sections.items.len - 1].fragment, a, id);
                } else if (std.ascii.eqlIgnoreCase(n, "code") or std.ascii.eqlIgnoreCase(n, "pre")) {
                    code_depth += 1;
                    // Word boundaries (#778): successive code fragments in a
                    // section must not concatenate ("fileotool -Lstrings"),
                    // and prose must not concatenate across an inline span's
                    // edges. normalize() collapses the padding whitespace.
                    try sections.items[sections.items.len - 1].code.append(a, ' ');
                    try sections.items[sections.items.len - 1].prose.append(a, ' ');
                }
                if (isBlock(n) or isBreak(n)) try sections.items[sections.items.len - 1].prose.append(a, ' ');
            }
        } else if (excluded > 0) excluded -= 1 else if (n.len == 2 and n[0] == 'h' and n[1] >= '1' and n[1] <= '6' and heading) {
            heading = false;
            const heading_title = try normalize(a, sections.items[sections.items.len - 1].heading.items);
            if (heading_marked or (level == 1 and title == null)) {
                if (title) |old| a.free(old);
                title = heading_title;
            } else a.free(heading_title);
            heading_marked = false;
        } else if ((std.ascii.eqlIgnoreCase(n, "code") or std.ascii.eqlIgnoreCase(n, "pre")) and code_depth > 0) {
            code_depth -= 1;
            // Close the prose word boundary opened by the span (#778).
            try sections.items[sections.items.len - 1].prose.append(a, ' ');
        }
        if (isBlock(n) and excluded == 0) try sections.items[sections.items.len - 1].prose.append(a, ' ');
        i = tag.end + 1;
    }
    if (title == null) {
        var ti: usize = 0;
        while (ti < html.len) {
            const s = std.mem.indexOfScalarPos(u8, html, ti, '<') orelse break;
            const t = tagAt(html, s) orelse break;
            if (!t.closing and std.ascii.eqlIgnoreCase(t.name, "title")) if (matchingRange(html, s, "title")) |r| {
                title = try decodeNormalize(a, html[r.start..r.end]);
                break;
            };
            ti = t.end + 1;
        }
    }
    if (title == null) title = try a.dupe(u8, path);
    if (sections.items.len > 1 and sections.items[0].heading.items.len == 0 and
        sections.items[0].prose.items.len == 0 and sections.items[0].code.items.len == 0)
    {
        // Drop the empty leading section by shifting the tail down, NOT by
        // advancing the slice. `sections.items = sections.items[1..]` moves the
        // ArrayList's base pointer, so the deferred `sections.deinit(a)` above
        // frees one element past the allocation — libmalloc aborts with SIGTRAP
        // (exit 133) after the HTML is already written, leaving an empty output
        // directory and no diagnostic. It also skipped element 0's four child
        // ArrayLists, leaking them. Debug builds tolerate the invalid free, so
        // the unit tests never saw it while CI ships ReleaseSafe.
        var first = sections.items[0];
        first.heading.deinit(a);
        first.fragment.deinit(a);
        first.prose.deinit(a);
        first.code.deinit(a);
        std.mem.copyForwards(
            MutableSection,
            sections.items[0 .. sections.items.len - 1],
            sections.items[1..],
        );
        sections.items.len -= 1;
    }
    var final = try a.alloc(Section, sections.items.len);
    errdefer a.free(final);
    for (sections.items, 0..) |*s, si| {
        const h = try normalize(a, s.heading.items);
        errdefer a.free(h);
        const text = try normalize(a, s.prose.items);
        errdefer a.free(text);
        const code = try normalize(a, s.code.items);
        errdefer a.free(code);
        const frag = if (s.fragment.items.len > 0) try a.dupe(u8, s.fragment.items) else try slugify(a, h);
        final[si] = .{ .level = s.level, .heading = h, .fragment = frag, .text = text, .code = code };
    }
    return .{ .path = try a.dupe(u8, path), .title = title.?, .sections = final };
}

/// Delegates to `json_out`, which is the one JSON escaper in this codebase.
/// This function used to be a copy of it with the `c < 0x20` branch missing, so
/// a control byte anywhere in a page's text shipped raw inside a JSON string
/// and the whole search index failed to parse — client search silently dead for
/// the entire site, not just that page. That is the cost of a second escaper.
fn jsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    try json_out.writeString(out, a, value);
}
pub fn writeJson(a: std.mem.Allocator, documents: []const Document) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "{\n  \"format\": \"boris-rendered-search-index\",\n  \"schema_version\": 1,\n  \"documents\": [");
    for (documents, 0..) |d, di| {
        if (di > 0) try out.appendSlice(a, ",");
        try out.appendSlice(a, "\n    {\n      \"path\": ");
        try jsonString(&out, a, d.path);
        try out.appendSlice(a, ",\n      \"title\": ");
        try jsonString(&out, a, d.title);
        try out.appendSlice(a, ",\n      \"sections\": [");
        for (d.sections, 0..) |s, si| {
            if (si > 0) try out.appendSlice(a, ",");
            var prefix: [96]u8 = undefined;
            const prefix_text = try std.fmt.bufPrint(&prefix, "\n        {{\"level\": {d}, \"heading\": ", .{s.level});
            try out.appendSlice(a, prefix_text);
            try jsonString(&out, a, s.heading);
            try out.appendSlice(a, ", \"fragment\": ");
            try jsonString(&out, a, s.fragment);
            try out.appendSlice(a, ", \"text\": ");
            try jsonString(&out, a, s.text);
            try out.appendSlice(a, ", \"code\": ");
            try jsonString(&out, a, s.code);
            try out.appendSlice(a, "}");
        }
        try out.appendSlice(a, "\n      ]\n    }");
    }
    try out.appendSlice(a, "\n  ]\n}\n");
    return out.toOwnedSlice(a);
}

fn readFileAlloc(io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn readOverlayFile(
    io: std.Io,
    staged_dir: std.Io.Dir,
    live_dir: std.Io.Dir,
    path: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    return readFileAlloc(io, staged_dir, path, allocator) catch |err| switch (err) {
        error.FileNotFound => readFileAlloc(io, live_dir, path, allocator),
        else => return err,
    };
}

/// Produce the target-owned search artifact from a staged/live HTML overlay.
///
/// `page_paths` is the complete live PageDb output set, not merely the dirty
/// set. A staged page wins when present; cached pages are read from `live_dir`.
/// This keeps search generation in the same target commit as HTML while
/// excluding removed pages from the new artifact.
pub fn writeOverlay(
    io: std.Io,
    allocator: std.mem.Allocator,
    staged_dir: std.Io.Dir,
    live_dir: std.Io.Dir,
    page_paths: []const []const u8,
    require_root_marker: bool,
) !void {
    const paths = try allocator.alloc([]const u8, page_paths.len);
    defer allocator.free(paths);
    @memcpy(paths, page_paths);
    std.mem.sort([]const u8, paths, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);

    var documents: std.ArrayList(Document) = .empty;
    defer {
        for (documents.items) |document| freeDocument(allocator, document);
        documents.deinit(allocator);
    }
    for (paths) |path| {
        const html = try readOverlayFile(io, staged_dir, live_dir, path, allocator);
        defer allocator.free(html);
        const document = try indexHtml(allocator, path, html, require_root_marker);
        try documents.append(allocator, document);
    }

    const json = try writeJson(allocator, documents.items);
    defer allocator.free(json);
    var atomic = try staged_dir.createFileAtomic(io, output_path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(json);
    try writer.interface.flush();
    try atomic.replace(io);
}

pub fn freeDocument(a: std.mem.Allocator, d: Document) void {
    a.free(d.path);
    a.free(d.title);
    for (d.sections) |s| {
        a.free(s.heading);
        a.free(s.fragment);
        a.free(s.text);
        a.free(s.code);
    }
    a.free(d.sections);
}

test "rendered extractor excludes chrome and preserves sections" {
    const html = "<html><head><title>Fallback</title></head><body><nav>Noise</nav><main data-boris-search-root><h1>Installing &amp; Boris</h1><p>Unicode café and &lt;escaped&gt;.</p><pre><code>zig build test</code></pre><h2 id=linux>Linux installation</h2><table><tr><td>arm64</td></tr></table><footer>Noise</footer></main></body></html>";
    const d = try indexHtml(std.testing.allocator, "guides/install.html", html, true);
    defer freeDocument(std.testing.allocator, d);
    try std.testing.expectEqualStrings("Installing & Boris", d.title);
    try std.testing.expectEqual(@as(usize, 2), d.sections.len);
    try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "café") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.sections[0].code, "zig build") != null);
    try std.testing.expectEqualStrings("linux", d.sections[1].fragment);
    try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "Noise") == null);
}

test "code fragments join with spaces and prose keeps word boundaries at span edges" {
    // #778: adjacent code spans must not concatenate in `code`, and the prose
    // around an inline span must not fuse into one token. Code stays out of
    // `text` (contract: rendered-search.md).
    const html = "<main data-boris-search-root><h1>Triage</h1>" ++
        "<p>Zero-build triage of the pack: <code>file</code>, <code>otool -L</code>, then <code>strings</code> mining.</p>" ++
        "</main>";
    const d = try indexHtml(std.testing.allocator, "triage.html", html, true);
    defer freeDocument(std.testing.allocator, d);
    const s = d.sections[0];
    try std.testing.expectEqualStrings("file otool -L strings", s.code);
    try std.testing.expectEqualStrings("Zero-build triage of the pack: , , then mining.", s.text);
}

test "explicit root failures stay fail-loud" {
    try std.testing.expectError(error.MultipleSearchRoots, indexHtml(
        std.testing.allocator,
        "index.html",
        "<main data-boris-search-root>x</main><main data-boris-search-root>y</main>",
        true,
    ));
    try std.testing.expectError(error.MissingSearchRoot, indexHtml(
        std.testing.allocator,
        "index.html",
        "<body><article>fallback is not allowed</article></body>",
        true,
    ));
}

test "a marker name inside another attribute's value is not a marker" {
    // A page documenting these markers slugifies the name into its heading id.
    // Matching that as a root gave MultipleSearchRoots on a page with one root.
    const html = "<main data-boris-search-root>" ++
        "<h3 id=\"document-root-marker-data-boris-search-root\">Document root marker</h3>" ++
        "<p>Prose about data-boris-search-root.</p>" ++
        "</main>";
    const d = try indexHtml(std.testing.allocator, "guides/search.html", html, true);
    defer freeDocument(std.testing.allocator, d);
    try std.testing.expectEqualStrings("document-root-marker-data-boris-search-root", d.sections[0].fragment);
}

test "attribute presence is matched by name, not by substring" {
    // Valueless markers must be found...
    try std.testing.expect(hasAttr("<main data-boris-search-root>", "data-boris-search-root"));
    try std.testing.expect(hasAttr("<main data-boris-search-root=\"\">", "data-boris-search-root"));
    try std.testing.expect(hasAttr("<main DATA-BORIS-SEARCH-ROOT>", "data-boris-search-root"));
    // ...without matching the name inside an id, class, or longer attribute.
    try std.testing.expect(!hasAttr("<h3 id=\"x-data-boris-search-root\">", "data-boris-search-root"));
    try std.testing.expect(!hasAttr("<div data-boris-search-root-note=\"x\">", "data-boris-search-root"));
    // `aria-hidden="false"` previously satisfied a test for `hidden`, which
    // dropped explicitly visible content from the index.
    try std.testing.expect(!hasAttr("<div aria-hidden=\"false\">", "hidden"));
    try std.testing.expect(hasAttr("<div hidden>", "hidden"));
    try std.testing.expect(!hasAttr("<span data-inert-marker=\"x\">", "inert"));
}

test "attrValue still reads only valued attributes" {
    try std.testing.expectEqualStrings("false", attrValue("<div aria-hidden=\"false\">", "aria-hidden").?);
    try std.testing.expectEqualStrings("x", attrValue("<div id='x'>", "id").?);
    try std.testing.expectEqualStrings("x", attrValue("<div id=x>", "id").?);
    try std.testing.expect(attrValue("<main data-boris-search-root>", "data-boris-search-root") == null);
}

test "explicitly visible content is indexed" {
    const html = "<main data-boris-search-root><div aria-hidden=\"false\"><p>Visible prose.</p></div></main>";
    const d = try indexHtml(std.testing.allocator, "index.html", html, true);
    defer freeDocument(std.testing.allocator, d);
    try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "Visible prose") != null);
}

fn headingFragment(d: Document, heading: []const u8) []const u8 {
    for (d.sections) |s| {
        if (std.mem.eql(u8, s.heading, heading)) return s.fragment;
    }
    return "";
}

fn sectionHaystack(d: Document) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    for (d.sections) |s| {
        try out.appendSlice(std.testing.allocator, s.heading);
        try out.append(std.testing.allocator, '\n');
        try out.appendSlice(std.testing.allocator, s.text);
        try out.append(std.testing.allocator, '\n');
        try out.appendSlice(std.testing.allocator, s.code);
        try out.append(std.testing.allocator, '\n');
    }
    return out.toOwnedSlice(std.testing.allocator);
}

test "fallback layout chrome is not indexed while page body is" {
    // Mirrors the Oliver Pages layout: no <main>, shared <aside> sidebar
    // headings, page-local content inside <article>.
    const html =
        \\<html><head><title>Fallback</title></head><body>
        \\<header class="site-header"><p>Oliver docs chrome</p></header>
        \\<article class="txp-content">
        \\<header class="article-header"><p>crumb</p></header>
        \\<h1 id="real-title">Real Title</h1>
        \\<p>Authored prose about widgets.</p>
        \\<pre><code>zig build test</code></pre>
        \\<table><tr><td>arm64</td></tr></table>
        \\<aside class="admonition"><p>Authored note stays searchable.</p></aside>
        \\</article>
        \\<aside class="txp-sidebar">
        \\<h2 id="search">Search</h2>
        \\<h2 id="on-this-page">On this page</h2>
        \\<h2 id="documentation">Documentation</h2>
        \\<h2 id="conformance">Conformance</h2>
        \\<h2 id="about-oliver">About Oliver</h2>
        \\<h2 id="publication">Publication</h2>
        \\<nav class="site-nav"><ul><li><a href="XHTML.html">XHTML</a></li><li>Cooklang</li><li>commonmark</li></ul></nav>
        \\</aside>
        \\<footer>shared footer chrome</footer>
        \\</body></html>
    ;
    const d = try indexHtml(std.testing.allocator, "guides/widgets.html", html, false);
    defer freeDocument(std.testing.allocator, d);
    const hay = try sectionHaystack(d);
    defer std.testing.allocator.free(hay);

    try std.testing.expectEqualStrings("Real Title", d.title);
    try std.testing.expect(d.sections.len >= 1);
    try std.testing.expectEqualStrings("real-title", headingFragment(d, "Real Title"));
    try std.testing.expect(std.mem.indexOf(u8, hay, "Authored prose about widgets") != null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "zig build test") != null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "arm64") != null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Authored note stays searchable") != null);

    try std.testing.expect(std.mem.indexOf(u8, hay, "Oliver docs chrome") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "shared footer chrome") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "XHTML") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Cooklang") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "commonmark") == null);
    for (d.sections) |s| {
        try std.testing.expect(std.mem.indexOf(u8, s.heading, "Search") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.heading, "On this page") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.heading, "Documentation") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.heading, "Conformance") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.heading, "About Oliver") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.heading, "Publication") == null);
    }
}

test "nested chrome headings do not leak after the first closer" {
    const html =
        \\<body>
        \\<nav><h2>Documentation</h2><ul><li>XHTML</li><li>Cooklang</li></ul></nav>
        \\<h1 id="page">Page</h1>
        \\<p>Only the body term widgets belongs here.</p>
        \\</body>
    ;
    const d = try indexHtml(std.testing.allocator, "index.html", html, false);
    defer freeDocument(std.testing.allocator, d);
    const hay = try sectionHaystack(d);
    defer std.testing.allocator.free(hay);
    try std.testing.expect(std.mem.indexOf(u8, hay, "widgets") != null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Documentation") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "XHTML") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Cooklang") == null);
}

test "explicit search ignore markers skip nested chrome" {
    const html =
        \\<main data-boris-search-root>
        \\<h1 id="keep">Keep heading</h1>
        \\<p>KeepTerm stays.</p>
        \\<div data-boris-search-ignore><h2>Ignored heading</h2><p>IgnoredIgnore</p></div>
        \\<section data-boris-noindex><p>NoindexTerm</p></section>
        \\<div data-boris-search-exclude><p>ExcludeTerm</p></div>
        \\</main>
    ;
    const d = try indexHtml(std.testing.allocator, "index.html", html, true);
    defer freeDocument(std.testing.allocator, d);
    const hay = try sectionHaystack(d);
    defer std.testing.allocator.free(hay);
    try std.testing.expectEqualStrings("keep", headingFragment(d, "Keep heading"));
    try std.testing.expect(std.mem.indexOf(u8, hay, "KeepTerm") != null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "IgnoredIgnore") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Ignored heading") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "NoindexTerm") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "ExcludeTerm") == null);
}

test "declared main still indexes authored asides and headers" {
    const html =
        \\<body>
        \\<aside class="sidebar"><h2>Documentation</h2><p>XHTML</p></aside>
        \\<main data-boris-search-root>
        \\<header><p>Article kicker</p></header>
        \\<h1 id="install">Installing</h1>
        \\<aside class="admonition"><p>Authored aside prose.</p></aside>
        \\</main>
        \\</body>
    ;
    const d = try indexHtml(std.testing.allocator, "guides/install.html", html, false);
    defer freeDocument(std.testing.allocator, d);
    const hay = try sectionHaystack(d);
    defer std.testing.allocator.free(hay);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Article kicker") != null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Authored aside prose") != null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Documentation") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "XHTML") == null);
}

test "body fallback excludes header and aside chrome" {
    const html =
        \\<body>
        \\<header>Site brand chrome</header>
        \\<div class="content"><h1 id="only">Only heading</h1><p>Local widgets prose.</p></div>
        \\<aside><h2>Documentation</h2><p>XHTML sidebar only</p></aside>
        \\<footer>Footer chrome</footer>
        \\</body>
    ;
    const d = try indexHtml(std.testing.allocator, "index.html", html, false);
    defer freeDocument(std.testing.allocator, d);
    const hay = try sectionHaystack(d);
    defer std.testing.allocator.free(hay);
    try std.testing.expectEqualStrings("only", headingFragment(d, "Only heading"));
    try std.testing.expect(std.mem.indexOf(u8, hay, "Local widgets prose") != null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Site brand chrome") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Documentation") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "XHTML sidebar only") == null);
    try std.testing.expect(std.mem.indexOf(u8, hay, "Footer chrome") == null);
}

test "search index JSON stays byte-deterministic" {
    const html = "<main data-boris-search-root><h1>Title</h1><p>Prose.</p></main>";
    const a = try indexHtml(std.testing.allocator, "index.html", html, true);
    defer freeDocument(std.testing.allocator, a);
    const b = try indexHtml(std.testing.allocator, "index.html", html, true);
    defer freeDocument(std.testing.allocator, b);
    const first = try writeJson(std.testing.allocator, &.{a});
    defer std.testing.allocator.free(first);
    const second = try writeJson(std.testing.allocator, &.{b});
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "table cells and breaks stay separate searchable words" {
    const html = "<main data-boris-search-root><h1>Targets</h1>" ++
        "<table><tr><th>Arch</th><td>arm64</td></tr><tr><td>x86</td><td>riscv</td></tr></table>" ++
        "<p>line<br>break</p></main>";
    const d = try indexHtml(std.testing.allocator, "index.html", html, true);
    defer freeDocument(std.testing.allocator, d);
    try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "Arch arm64") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "x86 riscv") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "arm64x86") == null);
    try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "line break") != null);
}

test "title fallback and heading fragments decode entities" {
    const html = "<html><head><title>Foo &amp; Bar</title></head>" ++
        "<main data-boris-search-root><h2 id=\"a&#38;b\">Later</h2><p>body</p></main></html>";
    const d = try indexHtml(std.testing.allocator, "index.html", html, true);
    defer freeDocument(std.testing.allocator, d);
    try std.testing.expectEqualStrings("Foo & Bar", d.title);
    try std.testing.expectEqualStrings("a&b", d.sections[0].fragment);
}

test "writeJson escapes control characters so the index stays parseable" {
    const gpa = std.testing.allocator;
    const sections = [_]Section{.{ .level = 1, .heading = "Heading\x01", .fragment = "h", .text = "body\x1f text", .code = "" }};
    const docs = [_]Document{.{ .path = "index.html", .title = "Title\x01", .sections = &sections }};
    const bytes = try writeJson(gpa, &docs);
    defer gpa.free(bytes);

    // A raw control byte inside a JSON string is invalid per RFC 8259, and one
    // bad byte anywhere makes the whole search index unparseable.
    for (bytes) |c| try std.testing.expect(c >= 0x20 or c == '\n');
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
}
