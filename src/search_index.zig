//! Deterministic search indexing for already-rendered Boris HTML.

const std = @import("std");

pub const format = "boris-rendered-search-index";
pub const schema_version: u32 = 1;
pub const output_path = "_boris/search/search-index.json";

pub const Error = error{ MultipleSearchRoots, MissingSearchRoot };

pub const Section = struct { level: u8, heading: []const u8, fragment: []const u8, text: []const u8, code: []const u8 };
pub const Document = struct { path: []const u8, title: []const u8, sections: []const Section };
const MutableSection = struct { level: u8 = 0, heading: std.ArrayList(u8) = .empty, fragment: std.ArrayList(u8) = .empty, prose: std.ArrayList(u8) = .empty, code: std.ArrayList(u8) = .empty };
const Tag = struct { name: []const u8, closing: bool, self_closing: bool, end: usize };
const Range = struct { start: usize, end: usize };

fn isNameChar(c: u8) bool { return std.ascii.isAlphanumeric(c) or c == '-' or c == ':'; }

fn tagAt(html: []const u8, start: usize) ?Tag {
    if (start >= html.len or html[start] != '<') return null;
    if (std.mem.startsWith(u8, html[start..], "<!--")) { const end = std.mem.indexOfPos(u8, html, start + 4, "-->") orelse return null; return .{ .name = "!comment", .closing = false, .self_closing = true, .end = end + 2 }; }
    var i = start + 1; var closing = false;
    if (i < html.len and html[i] == '/') { closing = true; i += 1; }
    while (i < html.len and std.ascii.isWhitespace(html[i])) : (i += 1) {}
    const name_start = i; while (i < html.len and isNameChar(html[i])) : (i += 1) {}
    if (i == name_start) return null; const name = html[name_start..i];
    var quote: ?u8 = null; var last_nonspace: u8 = 0;
    while (i < html.len) : (i += 1) { const c = html[i]; if (quote) |q| { if (c == q) quote = null; } else if (c == '"' or c == '\'') quote = c else if (c == '>') return .{ .name = name, .closing = closing, .self_closing = last_nonspace == '/', .end = i } else if (!std.ascii.isWhitespace(c)) last_nonspace = c; }
    return null;
}

fn attrValue(tag: []const u8, wanted: []const u8) ?[]const u8 {
    var i: usize = 1; if (i < tag.len and tag[i] == '/') i += 1; while (i < tag.len and isNameChar(tag[i])) : (i += 1) {}
    while (i < tag.len) { while (i < tag.len and (std.ascii.isWhitespace(tag[i]) or tag[i] == '/')) : (i += 1) {} if (i >= tag.len or tag[i] == '>') break; const ns = i; while (i < tag.len and isNameChar(tag[i])) : (i += 1) {} if (i == ns) { i += 1; continue; } const name = tag[ns..i]; while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {} if (i >= tag.len or tag[i] != '=') continue; i += 1; while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {} if (i >= tag.len) break; const q = tag[i]; if (q == '"' or q == '\'') { i += 1; const vs = i; while (i < tag.len and tag[i] != q) : (i += 1) {} if (std.ascii.eqlIgnoreCase(name, wanted)) return tag[vs..i]; if (i < tag.len) i += 1; } else { const vs = i; while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '>') : (i += 1) {} if (std.ascii.eqlIgnoreCase(name, wanted)) return tag[vs..i]; } }
    return null;
}

fn hasAttr(tag: []const u8, wanted: []const u8) bool { return attrValue(tag, wanted) != null or std.mem.indexOf(u8, tag, wanted) != null; }

fn matchingRange(html: []const u8, open_start: usize, name: []const u8) ?Range {
    const open = tagAt(html, open_start) orelse return null; var depth: usize = 1; var i = open.end + 1;
    while (i < html.len) { const next = std.mem.indexOfScalarPos(u8, html, i, '<') orelse break; const tag = tagAt(html, next) orelse { i = next + 1; continue; }; if (std.ascii.eqlIgnoreCase(tag.name, name) and !tag.self_closing) { if (tag.closing) { depth -= 1; if (depth == 0) return .{ .start = open.end + 1, .end = next }; } else depth += 1; } i = tag.end + 1; }
    return null;
}

fn findRoot(html: []const u8, require_marker: bool) Error!?Range {
    var explicit: ?usize = null; var count: usize = 0; var first_main: ?usize = null; var first_body: ?usize = null; var i: usize = 0;
    while (i < html.len) { const start = std.mem.indexOfScalarPos(u8, html, i, '<') orelse break; const tag = tagAt(html, start) orelse { i = start + 1; continue; }; if (!tag.closing and !tag.self_closing) { const t = html[start..tag.end + 1]; if (hasAttr(t, "data-boris-search-root")) { explicit = start; count += 1; } else if (first_main == null and std.ascii.eqlIgnoreCase(tag.name, "main")) first_main = start else if (first_body == null and std.ascii.eqlIgnoreCase(tag.name, "body")) first_body = start; } i = tag.end + 1; }
    if (count > 1) return error.MultipleSearchRoots; if (explicit) |s| return matchingRange(html, s, "main") orelse error.MissingSearchRoot; if (require_marker) return error.MissingSearchRoot; if (first_main) |s| return matchingRange(html, s, "main") orelse error.MissingSearchRoot; if (first_body) |s| return matchingRange(html, s, "body") orelse error.MissingSearchRoot; return null;
}

fn appendCodepoint(out: *std.ArrayList(u8), a: std.mem.Allocator, cp: u32) !void { if (cp <= 0x7f) return out.append(a, @intCast(cp)); if (cp <= 0x7ff) { try out.append(a, @intCast(0xc0 | (cp >> 6))); return out.append(a, @intCast(0x80 | (cp & 0x3f))); } if (cp <= 0xffff) { try out.append(a, @intCast(0xe0 | (cp >> 12))); try out.append(a, @intCast(0x80 | ((cp >> 6) & 0x3f))); return out.append(a, @intCast(0x80 | (cp & 0x3f))); } if (cp <= 0x10ffff) { try out.append(a, @intCast(0xf0 | (cp >> 18))); try out.append(a, @intCast(0x80 | ((cp >> 12) & 0x3f))); try out.append(a, @intCast(0x80 | ((cp >> 6) & 0x3f))); return out.append(a, @intCast(0x80 | (cp & 0x3f))); } }
fn appendEntity(out: *std.ArrayList(u8), a: std.mem.Allocator, e: []const u8) !bool { const pairs = .{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' }, .{ "nbsp", ' ' } }; inline for (pairs) |p| if (std.mem.eql(u8, e, p[0])) { try out.append(a, p[1]); return true; }; if (e.len > 1 and e[0] == '#') { var base: u8 = 10; var digits = e[1..]; if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X')) { base = 16; digits = digits[1..]; } const cp = std.fmt.parseInt(u32, digits, base) catch return false; try appendCodepoint(out, a, cp); return true; } return false; }
fn appendDecoded(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void { var i: usize = 0; while (i < text.len) { if (text[i] == '&') if (std.mem.indexOfScalarPos(u8, text, i + 1, ';')) |semi| if (try appendEntity(out, a, text[i + 1..semi])) { i = semi + 1; continue; }; try out.append(a, text[i]); i += 1; } }
fn normalize(a: std.mem.Allocator, raw: []const u8) ![]u8 { var out: std.ArrayList(u8) = .empty; errdefer out.deinit(a); var space = false; for (raw) |c| { if (std.ascii.isWhitespace(c)) { space = true; continue; } if (space and out.items.len > 0) try out.append(a, ' '); space = false; try out.append(a, c); } return out.toOwnedSlice(a); }
fn isBlock(n: []const u8) bool { return std.mem.eql(u8, n, "p") or std.mem.eql(u8, n, "div") or std.mem.eql(u8, n, "li") or std.mem.eql(u8, n, "section") or std.mem.eql(u8, n, "article") or std.mem.eql(u8, n, "blockquote") or std.mem.eql(u8, n, "pre") or std.mem.eql(u8, n, "details") or std.mem.eql(u8, n, "summary"); }
fn slugify(a: std.mem.Allocator, text: []const u8) ![]u8 { var out: std.ArrayList(u8) = .empty; errdefer out.deinit(a); var dash = false; for (text) |c| { if (std.ascii.isAlphanumeric(c)) { if (dash and out.items.len > 0) try out.append(a, '-'); dash = false; try out.append(a, std.ascii.toLower(c)); } else if (out.items.len > 0) dash = true; } return out.toOwnedSlice(a); }

pub fn indexHtml(a: std.mem.Allocator, path: []const u8, html: []const u8, require_marker: bool) !Document {
    const root: Range = try findRoot(html, require_marker) orelse Range{ .start = 0, .end = html.len };
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
    var title: ?[]u8 = null; var heading: bool = false; var heading_marked = false; var code_depth: usize = 0; var excluded: usize = 0; var level: u8 = 0; var i = root.start;
    while (i < root.end) { if (html[i] != '<') { const end = std.mem.indexOfScalarPos(u8, html, i, '<') orelse root.end; if (excluded == 0) { if (heading) try appendDecoded(&sections.items[sections.items.len - 1].heading, a, html[i..end]) else if (code_depth > 0) try appendDecoded(&sections.items[sections.items.len - 1].code, a, html[i..end]) else try appendDecoded(&sections.items[sections.items.len - 1].prose, a, html[i..end]); } i = end; continue; }
        const tag = tagAt(html, i) orelse { i += 1; continue; }; const txt = html[i..tag.end + 1]; const n = tag.name; if (n[0] == '!') { i = tag.end + 1; continue; }
        const hidden = hasAttr(txt, "hidden") or hasAttr(txt, "inert") or std.mem.eql(u8, attrValue(txt, "aria-hidden") orelse "", "true"); const excluded_name = std.ascii.eqlIgnoreCase(n, "nav") or std.ascii.eqlIgnoreCase(n, "footer") or std.ascii.eqlIgnoreCase(n, "script") or std.ascii.eqlIgnoreCase(n, "style") or std.ascii.eqlIgnoreCase(n, "template") or std.ascii.eqlIgnoreCase(n, "noscript") or std.ascii.eqlIgnoreCase(n, "svg") or std.ascii.eqlIgnoreCase(n, "canvas") or hasAttr(txt, "data-boris-search-exclude") or hidden;
        if (!tag.closing) { if (excluded_name and !tag.self_closing) excluded += 1; if (excluded == 0) { if (n.len == 2 and n[0] == 'h' and n[1] >= '1' and n[1] <= '6') { try sections.append(a, .{ .level = n[1] - '0' }); heading = true; heading_marked = attrValue(txt, "data-boris-search-title") != null; level = n[1] - '0'; if (attrValue(txt, "id")) |id| try sections.items[sections.items.len - 1].fragment.appendSlice(a, id); } else if (std.ascii.eqlIgnoreCase(n, "code") or std.ascii.eqlIgnoreCase(n, "pre")) code_depth += 1; if (isBlock(n)) try sections.items[sections.items.len - 1].prose.append(a, ' '); } } else if (excluded > 0) excluded -= 1 else if (n.len == 2 and n[0] == 'h' and n[1] >= '1' and n[1] <= '6' and heading) { heading = false; const heading_title = try normalize(a, sections.items[sections.items.len - 1].heading.items); if (heading_marked or (level == 1 and title == null)) { if (title) |old| a.free(old); title = heading_title; } else a.free(heading_title); heading_marked = false; } else if ((std.ascii.eqlIgnoreCase(n, "code") or std.ascii.eqlIgnoreCase(n, "pre")) and code_depth > 0) code_depth -= 1;
        if (isBlock(n) and excluded == 0) try sections.items[sections.items.len - 1].prose.append(a, ' '); i = tag.end + 1;
    }
    if (title == null) { var ti: usize = 0; while (ti < html.len) { const s = std.mem.indexOfScalarPos(u8, html, ti, '<') orelse break; const t = tagAt(html, s) orelse break; if (!t.closing and std.ascii.eqlIgnoreCase(t.name, "title")) if (matchingRange(html, s, "title")) |r| { title = try normalize(a, html[r.start..r.end]); break; }; ti = t.end + 1; } }
    if (title == null) title = try a.dupe(u8, path);
    if (sections.items.len > 1 and sections.items[0].heading.items.len == 0 and
        sections.items[0].prose.items.len == 0 and sections.items[0].code.items.len == 0)
    {
        sections.items = sections.items[1..];
    }
    var final = try a.alloc(Section, sections.items.len); errdefer a.free(final);
    for (sections.items, 0..) |*s, si| { const h = try normalize(a, s.heading.items); errdefer a.free(h); const text = try normalize(a, s.prose.items); errdefer a.free(text); const code = try normalize(a, s.code.items); errdefer a.free(code); const frag = if (s.fragment.items.len > 0) try a.dupe(u8, s.fragment.items) else try slugify(a, h); final[si] = .{ .level = s.level, .heading = h, .fragment = frag, .text = text, .code = code }; }
    return .{ .path = try a.dupe(u8, path), .title = title.?, .sections = final };
}

fn jsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void { try out.append(a, '"'); for (value) |c| switch (c) { '"' => try out.appendSlice(a, "\\\""), '\\' => try out.appendSlice(a, "\\\\"), '\n' => try out.appendSlice(a, "\\n"), '\r' => try out.appendSlice(a, "\\r"), '\t' => try out.appendSlice(a, "\\t"), else => try out.append(a, c) }; try out.append(a, '"'); }
pub fn writeJson(a: std.mem.Allocator, documents: []const Document) ![]u8 { var out: std.ArrayList(u8) = .empty; errdefer out.deinit(a); try out.appendSlice(a, "{\n  \"format\": \"boris-rendered-search-index\",\n  \"schema_version\": 1,\n  \"documents\": ["); for (documents, 0..) |d, di| { if (di > 0) try out.appendSlice(a, ","); try out.appendSlice(a, "\n    {\n      \"path\": "); try jsonString(&out, a, d.path); try out.appendSlice(a, ",\n      \"title\": "); try jsonString(&out, a, d.title); try out.appendSlice(a, ",\n      \"sections\": ["); for (d.sections, 0..) |s, si| { if (si > 0) try out.appendSlice(a, ","); var prefix: [96]u8 = undefined; const prefix_text = try std.fmt.bufPrint(&prefix, "\n        {{\"level\": {d}, \"heading\": ", .{s.level}); try out.appendSlice(a, prefix_text); try jsonString(&out, a, s.heading); try out.appendSlice(a, ", \"fragment\": "); try jsonString(&out, a, s.fragment); try out.appendSlice(a, ", \"text\": "); try jsonString(&out, a, s.text); try out.appendSlice(a, ", \"code\": "); try jsonString(&out, a, s.code); try out.appendSlice(a, "}"); } try out.appendSlice(a, "\n      ]\n    }"); } try out.appendSlice(a, "\n  ]\n}\n"); return out.toOwnedSlice(a); }

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

pub fn freeDocument(a: std.mem.Allocator, d: Document) void { a.free(d.path); a.free(d.title); for (d.sections) |s| { a.free(s.heading); a.free(s.fragment); a.free(s.text); a.free(s.code); } a.free(d.sections); }

test "rendered extractor excludes chrome and preserves sections" { const html = "<html><head><title>Fallback</title></head><body><nav>Noise</nav><main data-boris-search-root><h1>Installing &amp; Boris</h1><p>Unicode café and &lt;escaped&gt;.</p><pre><code>zig build test</code></pre><h2 id=linux>Linux installation</h2><table><tr><td>arm64</td></tr></table><footer>Noise</footer></main></body></html>"; const d = try indexHtml(std.testing.allocator, "guides/install.html", html, true); defer freeDocument(std.testing.allocator, d); try std.testing.expectEqualStrings("Installing & Boris", d.title); try std.testing.expectEqual(@as(usize, 2), d.sections.len); try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "café") != null); try std.testing.expect(std.mem.indexOf(u8, d.sections[0].code, "zig build") != null); try std.testing.expectEqualStrings("linux", d.sections[1].fragment); try std.testing.expect(std.mem.indexOf(u8, d.sections[0].text, "Noise") == null); }

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
