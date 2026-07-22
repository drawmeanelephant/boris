//! Graph-backed Markdown documentation-link rewriting before Apex.
//!
//! This is intentionally a small Markdown boundary, not an HTML replacement
//! pass. It recognizes inline Markdown links outside fences, code spans, and
//! raw HTML, resolves an existing page source through the frozen graph, and
//! emits Boris's canonical relative HTML href.

const std = @import("std");
const graph_mod = @import("graph.zig");
const identity = @import("identity.zig");

pub const Options = struct {
    nodes: []const graph_mod.Node,
    source_path: []const u8,
    output_path: []const u8,
};

const Destination = struct {
    start: usize,
    end: usize,
    link_end: usize,
};

fn isEscaped(body: []const u8, index: usize) bool {
    var slashes: usize = 0;
    var i = index;
    while (i > 0 and body[i - 1] == '\\') : (i -= 1) slashes += 1;
    return (slashes & 1) == 1;
}

fn lineEnd(body: []const u8, start: usize) usize {
    var i = start;
    while (i < body.len and body[i] != '\n') : (i += 1) {}
    return i;
}

fn atLineStart(body: []const u8, index: usize) bool {
    return index == 0 or body[index - 1] == '\n';
}

fn fenceAt(body: []const u8, index: usize) ?struct { ch: u8, run: usize } {
    if (!atLineStart(body, index)) return null;
    var i = index;
    var spaces: usize = 0;
    while (i < body.len and spaces < 4 and body[i] == ' ') : (i += 1) spaces += 1;
    if (i >= body.len or (body[i] != '`' and body[i] != '~')) return null;
    const ch = body[i];
    const start = i;
    while (i < body.len and body[i] == ch) : (i += 1) {}
    const run = i - start;
    if (run < 3) return null;
    return .{ .ch = ch, .run = run };
}

fn isBlockHtmlTag(name: []const u8) bool {
    const tags = [_][]const u8{
        "address", "article",  "aside",      "base",    "blockquote", "body",   "caption", "center",
        "col",     "colgroup", "dd",         "details", "dialog",     "dir",    "div",     "dl",
        "dt",      "fieldset", "figcaption", "figure",  "footer",     "form",   "h1",      "h2",
        "h3",      "h4",       "h5",         "h6",      "head",       "header", "hr",      "html",
        "iframe",  "legend",   "li",         "link",    "main",       "menu",   "nav",     "ol",
        "p",       "pre",      "script",     "section", "summary",    "table",  "tbody",   "td",
        "tfoot",   "th",       "thead",      "title",   "tr",         "track",  "ul",
    };
    for (tags) |tag| if (std.ascii.eqlIgnoreCase(tag, name)) return true;
    return false;
}

fn blockHtmlAt(body: []const u8, index: usize) bool {
    if (!atLineStart(body, index)) return false;
    var i = index;
    var spaces: usize = 0;
    while (i < body.len and spaces < 4 and body[i] == ' ') : (i += 1) spaces += 1;
    if (i >= body.len or body[i] != '<') return false;
    if (std.mem.startsWith(u8, body[i..], "<!--") or
        std.mem.startsWith(u8, body[i..], "<?") or
        std.mem.startsWith(u8, body[i..], "<![CDATA[")) return true;
    i += 1;
    if (i < body.len and body[i] == '/') i += 1;
    const start = i;
    while (i < body.len and std.ascii.isAlphabetic(body[i])) : (i += 1) {}
    return i > start and isBlockHtmlTag(body[start..i]);
}

fn findLabelEnd(body: []const u8, open: usize) ?usize {
    var nested: usize = 0;
    var i = open + 1;
    while (i < body.len) : (i += 1) {
        if (isEscaped(body, i)) continue;
        switch (body[i]) {
            '[' => nested += 1,
            ']' => {
                if (nested == 0) return i;
                nested -= 1;
            },
            '\n', '\r' => return null,
            else => {},
        }
    }
    return null;
}

fn skipSpace(body: []const u8, index: usize) usize {
    var i = index;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) : (i += 1) {}
    return i;
}

fn findTitleEnd(body: []const u8, start: usize, closing: u8) ?usize {
    var i = start + 1;
    while (i < body.len) : (i += 1) {
        if (body[i] == closing and !isEscaped(body, i)) return i + 1;
    }
    return null;
}

fn parseDestination(body: []const u8, open_paren: usize) ?Destination {
    var i = open_paren + 1;
    if (i >= body.len) return null;

    const dest_start: usize = if (body[i] == '<') i + 1 else i;
    if (body[i] == '<') {
        i += 1;
        while (i < body.len) : (i += 1) {
            if (body[i] == '>' and !isEscaped(body, i)) break;
        }
        if (i >= body.len or body[i] != '>') return null;
    } else {
        var parens: usize = 0;
        while (i < body.len) : (i += 1) {
            if (isEscaped(body, i)) continue;
            switch (body[i]) {
                '(' => parens += 1,
                ')' => {
                    if (parens == 0) break;
                    parens -= 1;
                },
                ' ', '\t', '\n', '\r' => if (parens == 0) break,
                else => {},
            }
        }
    }
    const dest_end = if (body[open_paren + 1] == '<') i else i;
    if (dest_end == dest_start) return null;

    i = skipSpace(body, if (body[open_paren + 1] == '<') i + 1 else i);
    if (i >= body.len) return null;
    if (body[i] == ')') return .{ .start = dest_start, .end = dest_end, .link_end = i + 1 };

    if (body[i] == '"' or body[i] == '\'' or body[i] == '(') {
        const closing = if (body[i] == '(') ')' else body[i];
        const title_end = findTitleEnd(body, i, closing) orelse return null;
        i = skipSpace(body, title_end);
        if (i < body.len and body[i] == ')') {
            return .{ .start = dest_start, .end = dest_end, .link_end = i + 1 };
        }
    }
    return null;
}

fn schemePrefix(path: []const u8) bool {
    if (path.len == 0 or !std.ascii.isAlphabetic(path[0])) return false;
    var i: usize = 1;
    while (i < path.len and (std.ascii.isAlphanumeric(path[i]) or path[i] == '+' or path[i] == '-' or path[i] == '.')) : (i += 1) {}
    return i < path.len and path[i] == ':';
}

fn hex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Fail closed on encoded dot/slash traversal instead of trying to interpret
/// URL escapes as filesystem names.
fn encodedTraversal(segment: []const u8) bool {
    if (std.mem.indexOfScalar(u8, segment, '%') == null) return false;
    var decoded: [256]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        var c = segment[i];
        if (c == '%') {
            if (i + 2 >= segment.len) return true;
            const hi = hex(segment[i + 1]) orelse return true;
            const lo = hex(segment[i + 2]) orelse return true;
            c = (hi << 4) | lo;
            i += 2;
        }
        if (n >= decoded.len) return true;
        decoded[n] = c;
        n += 1;
    }
    if (std.mem.indexOfScalar(u8, decoded[0..n], '/') != null or
        std.mem.indexOfScalar(u8, decoded[0..n], '\\') != null) return true;
    return std.mem.eql(u8, decoded[0..n], ".") or std.mem.eql(u8, decoded[0..n], "..");
}

fn splitPath(path: []const u8, out: *[128][]const u8) ?usize {
    if (path.len == 0) return 0;
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            if (i == start) return null;
            if (n == out.len) return null;
            out[n] = path[start..i];
            n += 1;
            start = i + 1;
        }
    }
    return n;
}

/// Resolve an author-facing Markdown path against the content-root source
/// namespace. This is source lookup, not public URL construction.
fn resolveSourcePath(allocator: std.mem.Allocator, source_path: []const u8, raw_path: []const u8) !?[]u8 {
    if (raw_path.len == 0 or std.mem.indexOfAny(u8, raw_path, "\\\t\r\n ") != null) return null;
    if (std.mem.startsWith(u8, raw_path, "//") or schemePrefix(raw_path)) return null;

    var parts: [128][]const u8 = undefined;
    var count: usize = 0;
    const root_relative = raw_path[0] == '/';
    if (!root_relative) {
        const slash = std.mem.lastIndexOfScalar(u8, source_path, '/') orelse 0;
        const dir = source_path[0..slash];
        const dir_count = splitPath(dir, &parts) orelse return null;
        count = dir_count;
    }

    const path = if (root_relative) raw_path[1..] else raw_path;
    var incoming: [128][]const u8 = undefined;
    const incoming_count = splitPath(path, &incoming) orelse return null;
    for (incoming[0..incoming_count]) |segment| {
        if (encodedTraversal(segment)) return null;
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (count == 0) return null;
            count -= 1;
        } else {
            if (count == parts.len) return null;
            parts[count] = segment;
            count += 1;
        }
    }
    if (count == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts[0..count], 0..) |segment, index| {
        if (index > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }
    return try out.toOwnedSlice(allocator);
}

fn findNodeBySource(map: *const std.StringHashMapUnmanaged(graph_mod.Node), path: []const u8) ?graph_mod.Node {
    return map.get(path);
}

fn splitSuffix(destination: []const u8) struct { path: []const u8, suffix: []const u8 } {
    var i: usize = 0;
    while (i < destination.len and destination[i] != '?' and destination[i] != '#') : (i += 1) {}
    return .{ .path = destination[0..i], .suffix = destination[i..] };
}

fn rewriteDestination(allocator: std.mem.Allocator, destination: []const u8, options: Options, nodes: *const std.StringHashMapUnmanaged(graph_mod.Node)) !?[]u8 {
    const split = splitSuffix(destination);
    if (!(std.mem.endsWith(u8, split.path, ".md") or std.mem.endsWith(u8, split.path, ".mdx"))) return null;
    const resolved = try resolveSourcePath(allocator, options.source_path, split.path) orelse return null;
    defer allocator.free(resolved);
    const node = findNodeBySource(nodes, resolved) orelse return null;
    const target_output = identity.htmlOutputPath(allocator, node.id) catch return null;
    defer allocator.free(target_output);
    const href = identity.relativeHref(allocator, options.output_path, target_output) catch return null;
    defer allocator.free(href);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ href, split.suffix });
}

pub fn rewrite(allocator: std.mem.Allocator, body: []const u8, options: Options) ![]u8 {
    var nodes: std.StringHashMapUnmanaged(graph_mod.Node) = .{};
    defer nodes.deinit(allocator);
    try nodes.ensureTotalCapacity(allocator, @intCast(options.nodes.len));
    for (options.nodes) |node| {
        const gop = try nodes.getOrPut(allocator, node.source_path);
        if (!gop.found_existing) gop.value_ptr.* = node;
    }
    if (options.nodes.len == 0) return try allocator.dupe(u8, body);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var copy_from: usize = 0;
    var i: usize = 0;
    var fence_ch: u8 = 0;
    var fence_run: usize = 0;
    var code_run: usize = 0;
    var html_block = false;

    while (i < body.len) {
        if (atLineStart(body, i)) {
            if (html_block) {
                if (lineEnd(body, i) == i) {
                    html_block = false;
                } else {
                    i = lineEnd(body, i);
                    if (i < body.len) i += 1;
                    continue;
                }
            }
            if (fenceAt(body, i)) |f| {
                if (fence_ch == 0) {
                    fence_ch = f.ch;
                    fence_run = f.run;
                } else if (f.ch == fence_ch and f.run >= fence_run) {
                    fence_ch = 0;
                    fence_run = 0;
                }
                i = lineEnd(body, i);
                if (i < body.len) i += 1;
                continue;
            }
            if (fence_ch == 0 and blockHtmlAt(body, i)) {
                html_block = true;
                i = lineEnd(body, i);
                if (i < body.len) i += 1;
                continue;
            }
        }
        if (fence_ch != 0) {
            i += 1;
            continue;
        }
        if (html_block) {
            i += 1;
            continue;
        }
        if (body[i] == '<') {
            if (std.mem.startsWith(u8, body[i..], "<!--")) {
                const end = std.mem.indexOf(u8, body[i + 4 ..], "-->");
                if (end != null) {
                    i = i + 4 + end.? + 3;
                } else {
                    i = body.len;
                }
            } else {
                while (i < body.len and body[i] != '>') : (i += 1) {}
                if (i < body.len) i += 1;
            }
            continue;
        }
        if (body[i] == '`') {
            var run: usize = 0;
            while (i + run < body.len and body[i + run] == '`') : (run += 1) {}
            if (code_run == 0 or code_run == run) code_run = if (code_run == 0) run else 0;
            i += run;
            continue;
        }
        if (code_run != 0) {
            i += 1;
            continue;
        }
        if (body[i] == '[' and (i == 0 or body[i - 1] != '!')) {
            if (findLabelEnd(body, i)) |label_end| {
                if (label_end + 1 < body.len and body[label_end + 1] == '(') {
                    if (parseDestination(body, label_end + 1)) |dest| {
                        const maybe = try rewriteDestination(allocator, body[dest.start..dest.end], options, &nodes);
                        if (maybe) |href| {
                            defer allocator.free(href);
                            try out.appendSlice(allocator, body[copy_from..dest.start]);
                            try out.appendSlice(allocator, href);
                            copy_from = dest.end;
                        }
                        i = dest.link_end;
                        continue;
                    }
                }
            }
        }
        i += 1;
    }
    try out.appendSlice(allocator, body[copy_from..]);
    return try out.toOwnedSlice(allocator);
}

fn testNodes() [4]graph_mod.Node {
    return .{
        .{ .id = "guide", .source_path = "guide.md" },
        .{ .id = "nested/install", .source_path = "nested/install.md" },
        .{ .id = "nested/index", .source_path = "nested/index.md" },
        .{ .id = "guide.mdx", .source_path = "guide.mdx" },
    };
}

test "documentation links resolve relative and root paths with suffixes" {
    const gpa = std.testing.allocator;
    const nodes = testNodes();
    const result = try rewrite(gpa, "[relative](../guide.md) [root](/guide.md?view=all#setup) [nested](../nested/index.md)", .{ .nodes = &nodes, .source_path = "docs/page.md", .output_path = "docs/page.html" });
    defer gpa.free(result);
    try std.testing.expectEqualStrings(
        "[relative](../guide.html) [root](../guide.html?view=all#setup) [nested](../nested/index.html)",
        result,
    );
}

test "documentation links preserve titles, angle destinations, and escaping" {
    const gpa = std.testing.allocator;
    const nodes = testNodes();
    const result = try rewrite(gpa, "[Guide](<../guide.md?x=1&y=2#part> \"Read it\")", .{ .nodes = &nodes, .source_path = "docs/page.md", .output_path = "docs/page.html" });
    defer gpa.free(result);
    try std.testing.expectEqualStrings(
        "[Guide](<../guide.html?x=1&y=2#part> \"Read it\")",
        result,
    );
}

test "documentation links work in ordinary Markdown inline contexts" {
    const gpa = std.testing.allocator;
    const nodes = testNodes();
    const result = try rewrite(gpa, "# [Heading](../guide.md)\n\n* [List](../guide.md)\n\n> [Quote](../guide.md)\n\n| [Table](../guide.md) |\n| --- |\n", .{ .nodes = &nodes, .source_path = "docs/page.md", .output_path = "docs/page.html" });
    defer gpa.free(result);
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, result, offset, "../guide.html")) |found| {
        count += 1;
        offset = found + 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "documentation links leave excluded and unsafe forms literal" {
    const gpa = std.testing.allocator;
    const nodes = testNodes();
    const body =
        "[external](https://example.test/guide.md) [proto](//cdn.test/guide.md) " ++
        "[mail](mailto:guide.md) [tel](tel:guide.md) ![image](guide.md) " ++
        "[nonmd](guide.txt) [upper](guide.MD) [missing](missing.md) " ++
        "[escape](../../guide.md) [encoded](%2e%2e/guide.md) ` [code](guide.md) `\n" ++
        "```\n[code](guide.md)\n```\n" ++
        "<a href=\"guide.md\">[raw](guide.md)</a>\n\n" ++
        "[ok](../guide.md)";
    const result = try rewrite(gpa, body, .{ .nodes = &nodes, .source_path = "docs/page.md", .output_path = "docs/page.html" });
    defer gpa.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[ok](../guide.html)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[external](https://example.test/guide.md)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "![image](guide.md)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[code](guide.md)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[raw](guide.md)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[escape](../../guide.md)") != null);
}
