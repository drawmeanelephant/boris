//! Shared read-only HTML tag and attribute scanning.
//!
//! One tokenizer backs both the rendered-search extractor and the published
//! output link audit, so they cannot disagree about where a tag or an attribute
//! name begins and ends. A substring search is not sufficient for either: Boris
//! documents HTML on its own site, so `href="` occurs in prose and code, and a
//! marker name can appear inside another attribute's value.
//!
//! This is a pragmatic scanner for known-shape generated output, not a
//! standards-conformant HTML5 parser.

const std = @import("std");

pub const Tag = struct { name: []const u8, closing: bool, self_closing: bool, end: usize };
pub const Range = struct { start: usize, end: usize };

pub const MalformedKind = enum {
    unterminated_tag,
    unterminated_comment,
    unterminated_quoted_attribute,
    unterminated_raw_text,
};

pub const Malformed = struct {
    kind: MalformedKind,
    offset: usize,
};

pub const CheckedTag = union(enum) {
    tag: Tag,
    not_a_tag,
    malformed: Malformed,
};

pub fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == ':';
}

pub fn tagAt(html: []const u8, start: usize) ?Tag {
    if (start >= html.len or html[start] != '<') return null;
    if (std.mem.startsWith(u8, html[start..], "<!--")) {
        const end = std.mem.indexOfPos(u8, html, start + 4, "-->") orelse return null;
        return .{ .name = "!comment", .closing = false, .self_closing = true, .end = end + 2 };
    }
    var i = start + 1;
    var closing = false;
    if (i < html.len and html[i] == '/') {
        closing = true;
        i += 1;
    }
    while (i < html.len and std.ascii.isWhitespace(html[i])) : (i += 1) {}
    const name_start = i;
    while (i < html.len and isNameChar(html[i])) : (i += 1) {}
    if (i == name_start) return null;
    const name = html[name_start..i];
    var quote: ?u8 = null;
    var last_nonspace: u8 = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') quote = c else if (c == '>') return .{ .name = name, .closing = closing, .self_closing = last_nonspace == '/', .end = i } else if (!std.ascii.isWhitespace(c)) last_nonspace = c;
    }
    return null;
}

/// Detailed counterpart to `tagAt`. Existing compiler/search callers keep the
/// historical optional API, while Doctor can distinguish bounded non-markup
/// from an unterminated structure that makes inspection incomplete.
pub fn checkedTagAt(html: []const u8, start: usize) CheckedTag {
    if (start >= html.len or html[start] != '<') return .not_a_tag;
    if (std.mem.startsWith(u8, html[start..], "<!--")) {
        const end = std.mem.indexOfPos(u8, html, start + 4, "-->") orelse {
            return .{ .malformed = .{ .kind = .unterminated_comment, .offset = start } };
        };
        return .{ .tag = .{
            .name = "!comment",
            .closing = false,
            .self_closing = true,
            .end = end + 2,
        } };
    }

    var i = start + 1;
    var closing = false;
    if (i < html.len and html[i] == '/') {
        closing = true;
        i += 1;
    }
    while (i < html.len and std.ascii.isWhitespace(html[i])) : (i += 1) {}
    const name_start = i;
    while (i < html.len and isNameChar(html[i])) : (i += 1) {}
    if (i == name_start) return .not_a_tag;
    const name = html[name_start..i];

    var quote: ?u8 = null;
    var quote_start: usize = 0;
    var last_nonspace: u8 = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') {
            quote = c;
            quote_start = i;
        } else if (c == '>') {
            return .{ .tag = .{
                .name = name,
                .closing = closing,
                .self_closing = last_nonspace == '/',
                .end = i,
            } };
        } else if (!std.ascii.isWhitespace(c)) {
            last_nonspace = c;
        }
    }
    if (quote != null) {
        return .{ .malformed = .{
            .kind = .unterminated_quoted_attribute,
            .offset = quote_start,
        } };
    }
    return .{ .malformed = .{ .kind = .unterminated_tag, .offset = start } };
}

/// One parsed attribute. `value` is null for a valueless (boolean) attribute
/// such as the marker in `<main data-boris-search-root>`.
pub const Attr = struct { name: []const u8, value: ?[]const u8 };

/// Walks a tag's attributes. One parser backs both `attrValue` and `hasAttr`
/// so they cannot disagree about where an attribute name starts and ends.
pub const AttrIter = struct {
    tag: []const u8,
    i: usize,

    pub fn init(tag: []const u8) AttrIter {
        var i: usize = 1;
        if (i < tag.len and tag[i] == '/') i += 1;
        while (i < tag.len and isNameChar(tag[i])) : (i += 1) {}
        return .{ .tag = tag, .i = i };
    }

    pub fn next(self: *AttrIter) ?Attr {
        const tag = self.tag;
        var i = self.i;
        while (i < tag.len) {
            while (i < tag.len and (std.ascii.isWhitespace(tag[i]) or tag[i] == '/')) : (i += 1) {}
            if (i >= tag.len or tag[i] == '>') break;
            const ns = i;
            while (i < tag.len and isNameChar(tag[i])) : (i += 1) {}
            if (i == ns) {
                i += 1;
                continue;
            }
            const name = tag[ns..i];
            var j = i;
            while (j < tag.len and std.ascii.isWhitespace(tag[j])) : (j += 1) {}
            // No `=` follows: a boolean attribute. Yield it rather than skip it.
            if (j >= tag.len or tag[j] != '=') {
                self.i = i;
                return .{ .name = name, .value = null };
            }
            j += 1;
            while (j < tag.len and std.ascii.isWhitespace(tag[j])) : (j += 1) {}
            if (j >= tag.len) break;
            const q = tag[j];
            if (q == '"' or q == '\'') {
                j += 1;
                const vs = j;
                while (j < tag.len and tag[j] != q) : (j += 1) {}
                const v = tag[vs..j];
                self.i = if (j < tag.len) j + 1 else j;
                return .{ .name = name, .value = v };
            }
            const vs = j;
            while (j < tag.len and !std.ascii.isWhitespace(tag[j]) and tag[j] != '>') : (j += 1) {}
            self.i = j;
            return .{ .name = name, .value = tag[vs..j] };
        }
        self.i = i;
        return null;
    }
};

/// Value of `wanted`, or null. A valueless attribute yields no value, which
/// preserves this function's previous behavior for its callers.
pub fn attrValue(tag: []const u8, wanted: []const u8) ?[]const u8 {
    var it = AttrIter.init(tag);
    while (it.next()) |a| {
        if (a.value) |v| {
            if (std.ascii.eqlIgnoreCase(a.name, wanted)) return v;
        }
    }
    return null;
}

/// True when `wanted` is present as an attribute NAME, with or without a value.
///
/// This is deliberately not a substring test. Boris documents these marker
/// names on its own site, and a heading id is slugified from its text, so
/// `<h3 id="document-root-marker-data-boris-search-root">` would otherwise
/// count as a second search root and fail the build with MultipleSearchRoots.
/// The same fault let `aria-hidden="false"` satisfy a test for `hidden`,
/// dropping explicitly visible content from the index.
pub fn hasAttr(tag: []const u8, wanted: []const u8) bool {
    var it = AttrIter.init(tag);
    while (it.next()) |a| {
        if (std.ascii.eqlIgnoreCase(a.name, wanted)) return true;
    }
    return false;
}

/// Elements whose text content is not markup. A reference written inside one of
/// these is documentation or script data, never a published link.
pub fn isRawTextElement(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "script") or
        std.ascii.eqlIgnoreCase(name, "style") or
        std.ascii.eqlIgnoreCase(name, "template") or
        std.ascii.eqlIgnoreCase(name, "noscript") or
        std.ascii.eqlIgnoreCase(name, "code") or
        std.ascii.eqlIgnoreCase(name, "pre") or
        std.ascii.eqlIgnoreCase(name, "textarea");
}

/// Find the content range inside the element opened at `open_start`, balancing
/// nested elements with the same name. This preserves the rendered-search
/// extractor's existing matching semantics while making the range reusable for
/// Doctor ownership attribution.
pub fn matchingRange(html: []const u8, open_start: usize, name: []const u8) ?Range {
    const open = tagAt(html, open_start) orelse return null;
    var depth: usize = 1;
    var i = open.end + 1;
    while (i < html.len) {
        const next = std.mem.indexOfScalarPos(u8, html, i, '<') orelse break;
        const tag = tagAt(html, next) orelse {
            i = next + 1;
            continue;
        };
        if (std.ascii.eqlIgnoreCase(tag.name, name) and !tag.self_closing) {
            if (tag.closing) {
                depth -= 1;
                if (depth == 0) return .{ .start = open.end + 1, .end = next };
            } else {
                depth += 1;
            }
        }
        i = tag.end + 1;
    }
    return null;
}

pub fn rawTextEnd(html: []const u8, content_start: usize, name: []const u8) ?usize {
    var i = content_start;
    while (i < html.len) {
        const next = std.mem.indexOfScalarPos(u8, html, i, '<') orelse return null;
        if (next + 1 < html.len and html[next + 1] == '/') {
            switch (checkedTagAt(html, next)) {
                .tag => |tag| {
                    if (tag.closing and std.ascii.eqlIgnoreCase(tag.name, name)) {
                        return tag.end + 1;
                    }
                    i = tag.end + 1;
                },
                .not_a_tag => i = next + 1,
                // A broken closing candidate means there is no provable raw
                // text terminator; report the opening element below.
                .malformed => return null,
            }
        } else {
            i = next + 1;
        }
    }
    return null;
}

/// Validate only the bounded structures Doctor must prove before claiming a
/// complete rendered audit. This is intentionally not tag-balance or HTML5
/// conformance validation.
pub fn validate(html: []const u8) ?Malformed {
    var i: usize = 0;
    while (i < html.len) {
        const start = std.mem.indexOfScalarPos(u8, html, i, '<') orelse break;
        switch (checkedTagAt(html, start)) {
            .not_a_tag => i = start + 1,
            .malformed => |malformed| return malformed,
            .tag => |tag| {
                if (!tag.closing and !tag.self_closing and isRawTextElement(tag.name)) {
                    i = rawTextEnd(html, tag.end + 1, tag.name) orelse {
                        return .{ .kind = .unterminated_raw_text, .offset = start };
                    };
                } else {
                    i = tag.end + 1;
                }
            },
        }
    }
    return null;
}

pub fn lineColumn(html: []const u8, offset: usize) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var column: u32 = 1;
    for (html[0..@min(offset, html.len)]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

test "raw-text elements are identified case-insensitively" {
    try std.testing.expect(isRawTextElement("CODE"));
    try std.testing.expect(isRawTextElement("pre"));
    try std.testing.expect(!isRawTextElement("div"));
}

test "a quoted angle bracket does not terminate the tag" {
    const html = "<a title=\"a > b\" href=\"real.html\">t</a>";
    const tag = tagAt(html, 0).?;
    try std.testing.expectEqualStrings("real.html", attrValue(html[0 .. tag.end + 1], "href").?);
}

test "comments are reported so their contents can be skipped" {
    try std.testing.expectEqualStrings("!comment", tagAt("<!-- <a href=\"../x\">y</a> -->", 0).?.name);
}

test "checked validation identifies only bounded malformed structures" {
    try std.testing.expectEqual(
        MalformedKind.unterminated_tag,
        validate("<main><a href=x").?.kind,
    );
    try std.testing.expectEqual(
        MalformedKind.unterminated_comment,
        validate("<main><!-- never closed").?.kind,
    );
    try std.testing.expectEqual(
        MalformedKind.unterminated_quoted_attribute,
        validate("<a href=\"never closed>").?.kind,
    );
    try std.testing.expectEqual(
        MalformedKind.unterminated_raw_text,
        validate("<script>const x = '<a>';").?.kind,
    );
    try std.testing.expect(validate("<unknown data-x='bounded'>ok</unknown>") == null);
    try std.testing.expect(validate("<script>const x = '<a href=\"fake\">';</script>") == null);
}

test "checked locations use one-based byte columns" {
    const loc = lineColumn("<p>x</p>\n  <a>", 11);
    try std.testing.expectEqual(@as(u32, 2), loc.line);
    try std.testing.expectEqual(@as(u32, 3), loc.column);
}
