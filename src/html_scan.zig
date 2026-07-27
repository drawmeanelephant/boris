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

/// One parsed attribute. `value` is null for a valueless (boolean) attribute
/// such as the marker in `<main data-boris-search-root>`.
pub const Attr = struct { name: []const u8, value: ?[]const u8 };

/// Walks a tag's attributes. One parser backs both `attrValue` and `hasAttr`
/// so they cannot disagree about where an attribute name starts and ends.
pub const AttrIter = struct {
    tag: []const u8,
    i: usize,

    fn init(tag: []const u8) AttrIter {
        var i: usize = 1;
        if (i < tag.len and tag[i] == '/') i += 1;
        while (i < tag.len and isNameChar(tag[i])) : (i += 1) {}
        return .{ .tag = tag, .i = i };
    }

    fn next(self: *AttrIter) ?Attr {
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
