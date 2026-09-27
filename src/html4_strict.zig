//! Fail-closed whole-document check for the HTML 4.01 Strict subset Boris
//! publishes. This is deliberately narrower than the SGML DTD: an unfamiliar
//! tag, attribute, entity, or content model is an error, never an assertion
//! that Oliver's fragment serializer certified the surrounding layout.
const std = @import("std");

pub const doctype = "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">";

pub const Finding = struct {
    offset: usize,
    reason: []const u8,
    detail: []const u8 = "",
};

fn member(list: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |item| if (std.mem.eql(u8, item, word)) return true;
    return false;
}

const empty = "br hr img meta link";
const block = "div p h1 h2 h3 h4 h5 h6 pre blockquote ul ol dl table hr";
const inline_tag = "a em strong b i del ins big small sup sub cite span code acronym abbr q br img";
const global = "id class style title lang dir";

fn childAllowed(parent: []const u8, child: []const u8) bool {
    if (member("html", parent)) return member("head body", child);
    if (member("head", parent)) return member("title meta link style", child);
    if (member("body", parent)) return member(block, child);
    if (member("div li dd th td", parent)) return member(block, child) or member(inline_tag, child);
    if (member("blockquote", parent)) return member(block, child);
    if (member("p h1 h2 h3 h4 h5 h6 dt a em strong b i del ins big small sup sub cite span code acronym abbr q", parent))
        return member(inline_tag, child);
    if (member("ul ol", parent)) return member("li", child);
    if (member("dl", parent)) return member("dt dd", child);
    if (member("table", parent)) return member("caption thead tfoot tbody", child);
    if (member("thead tfoot tbody", parent)) return member("tr", child);
    if (member("tr", parent)) return member("th td", child);
    if (member("pre", parent)) return member(inline_tag, child) and !member("img big small sup sub", child);
    if (member("caption", parent)) return member(inline_tag, child);
    return false;
}

fn attrAllowed(tag: []const u8, name: []const u8) bool {
    if (member(global, name) and !member("html head title meta link style", tag)) return true;
    if (member("html", tag)) return member("lang dir", name);
    if (member("meta", tag)) return member("http-equiv name content scheme", name);
    if (member("link", tag)) return member("href rel rev type charset hreflang media title", name);
    if (member("style", tag)) return member("type media title", name);
    if (member("a", tag)) return member("href name rel rev charset hreflang type accesskey tabindex", name);
    if (member("blockquote q", tag)) return member("cite", name);
    if (member("img", tag)) return member("src alt longdesc height width ismap", name);
    if (member("th td", tag)) return member("abbr axis headers scope rowspan colspan align char charoff valign", name);
    if (member("tr thead tbody tfoot", tag)) return member("align char charoff valign", name);
    if (member("table", tag)) return member("summary width border frame rules cellspacing cellpadding", name);
    return false;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or !std.ascii.isAlphabetic(id[0])) return false;
    for (id[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-_.:", c) == null) return false;
    }
    return true;
}

fn attrValueValid(name: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, name, "id")) return validId(value);
    if (std.mem.eql(u8, name, "dir")) return member("ltr rtl", value);
    if (std.mem.eql(u8, name, "align")) return member("left center right justify char", value);
    if (std.mem.eql(u8, name, "valign")) return member("top middle bottom baseline", value);
    if (std.mem.eql(u8, name, "scope")) return member("row col rowgroup colgroup", value);
    if (std.mem.eql(u8, name, "ismap")) return std.mem.eql(u8, value, "ismap");
    if (std.mem.eql(u8, name, "frame")) return member("void above below hsides lhs rhs vsides box border", value);
    if (std.mem.eql(u8, name, "rules")) return member("none groups rows cols all", value);
    if (member("rowspan colspan height width border cellspacing cellpadding", name)) {
        if (value.len == 0) return false;
        for (value) |c| if (!std.ascii.isDigit(c) and c != '%') return false;
    }
    return true;
}

fn space(c: u8) bool {
    return std.mem.indexOfScalar(u8, " \t\r\n", c) != null;
}

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_:", c) != null;
}

const Frame = struct {
    name: []const u8,
    children: usize = 0,
    phase: u8 = 0,
    tbody_count: usize = 0,
};

const Checker = struct {
    bytes: []const u8,
    pos: usize = 0,
    frames: [256]Frame = undefined,
    depth: usize = 0,
    ids: std.StringHashMapUnmanaged(void) = .empty,
    header_refs: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,
    failure: ?Finding = null,

    fn fail(self: *Checker, reason: []const u8, detail: []const u8) error{Invalid} {
        self.failure = .{ .offset = self.pos, .reason = reason, .detail = detail };
        return error.Invalid;
    }

    fn skipSpace(self: *Checker) void {
        while (self.pos < self.bytes.len and space(self.bytes[self.pos])) self.pos += 1;
    }

    fn scanName(self: *Checker) error{Invalid}![]const u8 {
        const start = self.pos;
        while (self.pos < self.bytes.len and nameChar(self.bytes[self.pos])) self.pos += 1;
        if (self.pos == start) return self.fail("expected an HTML name", "");
        return self.bytes[start..self.pos];
    }

    fn reference(self: *Checker) error{Invalid}!void {
        const start = self.pos;
        self.pos += 1;
        if (self.pos < self.bytes.len and self.bytes[self.pos] == '#') {
            self.pos += 1;
            var base: u8 = 10;
            if (self.pos < self.bytes.len and (self.bytes[self.pos] == 'x' or self.bytes[self.pos] == 'X')) {
                base = 16;
                self.pos += 1;
            }
            const number_start = self.pos;
            while (self.pos < self.bytes.len and std.ascii.isHex(self.bytes[self.pos])) self.pos += 1;
            if (self.pos == number_start or self.pos >= self.bytes.len or self.bytes[self.pos] != ';')
                return self.fail("invalid character reference", self.bytes[start..self.pos]);
            const n = std.fmt.parseInt(u32, self.bytes[number_start..self.pos], base) catch
                return self.fail("invalid character reference", self.bytes[start..self.pos]);
            if (n != 9 and n != 10 and n != 13 and (n < 32 or n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff)))
                return self.fail("invalid character reference", self.bytes[start..self.pos]);
            self.pos += 1;
            return;
        }
        const name = try self.scanName();
        if (self.pos >= self.bytes.len or self.bytes[self.pos] != ';' or
            !member("amp lt gt quot nbsp copy reg mdash ndash hellip lsquo rsquo ldquo rdquo trade euro bull middot", name))
            return self.fail("unsupported or malformed HTML entity", name);
        self.pos += 1;
    }

    fn addChild(self: *Checker, tag: []const u8) error{Invalid}!void {
        if (self.depth == 0) {
            if (!std.mem.eql(u8, tag, "html")) return self.fail("document root must be html", tag);
            return;
        }
        const parent = &self.frames[self.depth - 1];
        if (!childAllowed(parent.name, tag)) return self.fail("element is not allowed in its parent", tag);
        if (std.mem.eql(u8, tag, "a")) {
            for (self.frames[0..self.depth]) |frame| {
                if (std.mem.eql(u8, frame.name, "a")) return self.fail("nested links are not allowed", tag);
            }
        }
        if (member("img big small sup sub", tag)) {
            for (self.frames[0..self.depth]) |frame| {
                if (std.mem.eql(u8, frame.name, "pre")) return self.fail("element excluded inside pre", tag);
            }
        }
        if (std.mem.eql(u8, parent.name, "html")) {
            const expected: []const u8 = if (parent.children == 0) "head" else "body";
            if (!std.mem.eql(u8, tag, expected) or parent.children >= 2)
                return self.fail("html requires head followed by body", tag);
        }
        if (std.mem.eql(u8, parent.name, "head")) {
            if (std.mem.eql(u8, tag, "title")) {
                if (parent.phase != 0) return self.fail("head requires one title", tag);
                parent.phase = 1;
            } else if (std.mem.eql(u8, tag, "style")) {
                if (parent.phase != 1) return self.fail("head requires a title", tag);
            }
        }
        if (std.mem.eql(u8, parent.name, "table")) {
            const phase: u8 = if (std.mem.eql(u8, tag, "caption")) 0 else if (std.mem.eql(u8, tag, "thead")) 1 else if (std.mem.eql(u8, tag, "tfoot")) 2 else 3;
            if ((phase == 0 and parent.children != 0) or phase < parent.phase or
                (phase != 3 and phase == parent.phase and parent.children != 0))
                return self.fail("invalid table section order", tag);
            parent.phase = phase;
            if (phase == 3) parent.tbody_count += 1;
        }
        parent.children += 1;
    }

    fn finish(self: *Checker, frame: Frame) error{Invalid}!void {
        if (std.mem.eql(u8, frame.name, "html") and frame.children != 2) return self.fail("html requires head and body", "");
        if (std.mem.eql(u8, frame.name, "head") and frame.phase != 1) return self.fail("head requires exactly one title", "");
        if (member("ul ol dl blockquote thead tfoot tbody tr", frame.name) and frame.children == 0)
            return self.fail("container needs at least one child", frame.name);
        if (std.mem.eql(u8, frame.name, "table") and frame.tbody_count == 0)
            return self.fail("table needs at least one tbody", "");
        if (std.mem.eql(u8, frame.name, "body") and frame.children == 0)
            return self.fail("body needs at least one block", "");
    }

    fn run(self: *Checker) (error{ Invalid, OutOfMemory })!void {
        if (!std.unicode.utf8ValidateSlice(self.bytes)) return self.fail("document is not UTF-8", "");
        if (!std.mem.startsWith(u8, self.bytes, doctype)) return self.fail("missing HTML 4.01 Strict DOCTYPE", "");
        self.pos = doctype.len;
        var root_seen = false;
        while (self.pos < self.bytes.len) {
            if (self.bytes[self.pos] != '<') {
                if (self.depth == 0 and !space(self.bytes[self.pos])) return self.fail("text outside html", "");
                if (self.depth > 0 and member("html head body ul ol dl table thead tfoot tbody tr", self.frames[self.depth - 1].name) and !space(self.bytes[self.pos]))
                    return self.fail("text is not allowed in this container", self.frames[self.depth - 1].name);
                if (self.bytes[self.pos] == '&') {
                    try self.reference();
                } else {
                    const c = self.bytes[self.pos];
                    if ((c < 32 and !space(c)) or c == 127) return self.fail("invalid control character", "");
                    self.pos += 1;
                }
                continue;
            }
            self.pos += 1;
            if (self.pos >= self.bytes.len) return self.fail("unterminated tag", "");
            if (self.bytes[self.pos] == '/') {
                self.pos += 1;
                const tag = try self.scanName();
                self.skipSpace();
                if (self.pos >= self.bytes.len or self.bytes[self.pos] != '>' or self.depth == 0)
                    return self.fail("unbalanced closing tag", tag);
                self.pos += 1;
                self.depth -= 1;
                const frame = self.frames[self.depth];
                if (!std.mem.eql(u8, frame.name, tag)) return self.fail("mismatched closing tag", tag);
                try self.finish(frame);
                continue;
            }
            const tag = try self.scanName();
            if (!member(block, tag) and !member(inline_tag, tag) and
                !member("html head body title meta link style li dt dd caption thead tfoot tbody tr th td", tag))
                return self.fail("unsupported HTML 4.01 Strict element", tag);
            if (self.depth == 0) {
                if (root_seen) return self.fail("multiple document roots", tag);
                root_seen = true;
            }
            try self.addChild(tag);
            var seen_attrs: [32][]const u8 = undefined;
            var attr_count: usize = 0;
            var img_src = false;
            var img_alt = false;
            var meta_content = false;
            var style_type = false;
            while (true) {
                const before = self.pos;
                self.skipSpace();
                if (self.pos >= self.bytes.len) return self.fail("unterminated opening tag", tag);
                if (self.bytes[self.pos] == '>') {
                    self.pos += 1;
                    break;
                }
                if (before == self.pos) return self.fail("attribute needs whitespace", tag);
                const attr = try self.scanName();
                if (!attrAllowed(tag, attr)) return self.fail("unsupported HTML 4.01 Strict attribute", attr);
                for (seen_attrs[0..attr_count]) |prior| {
                    if (std.mem.eql(u8, prior, attr)) return self.fail("duplicate attribute", attr);
                }
                if (attr_count == seen_attrs.len) return self.fail("too many attributes", tag);
                seen_attrs[attr_count] = attr;
                attr_count += 1;
                self.skipSpace();
                if (self.pos >= self.bytes.len or self.bytes[self.pos] != '=') return self.fail("attribute needs a quoted value", attr);
                self.pos += 1;
                self.skipSpace();
                if (self.pos >= self.bytes.len or self.bytes[self.pos] != '"') return self.fail("attribute needs double quotes", attr);
                self.pos += 1;
                const value_start = self.pos;
                while (self.pos < self.bytes.len and self.bytes[self.pos] != '"') {
                    if (self.bytes[self.pos] == '<' or self.bytes[self.pos] == '>')
                        return self.fail("unescaped attribute value", attr);
                    if (self.bytes[self.pos] == '&') try self.reference() else self.pos += 1;
                }
                if (self.pos == self.bytes.len) return self.fail("unterminated attribute value", attr);
                const value = self.bytes[value_start..self.pos];
                if (!attrValueValid(attr, value)) return self.fail("invalid HTML 4.01 Strict attribute value", attr);
                if (std.mem.eql(u8, attr, "id")) {
                    const entry = try self.ids.getOrPut(self.allocator, value);
                    if (entry.found_existing) return self.fail("duplicate document id", value);
                }
                if (std.mem.eql(u8, attr, "headers")) {
                    var refs = std.mem.tokenizeAny(u8, value, " \t\r\n");
                    var has_ref = false;
                    while (refs.next()) |ref| {
                        if (!validId(ref)) return self.fail("invalid header reference", ref);
                        try self.header_refs.append(self.allocator, ref);
                        has_ref = true;
                    }
                    if (!has_ref) return self.fail("headers requires an id reference", "");
                }
                if (std.mem.eql(u8, attr, "src")) img_src = true;
                if (std.mem.eql(u8, attr, "alt")) img_alt = true;
                if (std.mem.eql(u8, attr, "content")) meta_content = true;
                if (std.mem.eql(u8, attr, "type")) style_type = true;
                self.pos += 1;
            }
            if (std.mem.eql(u8, tag, "img") and (!img_src or !img_alt)) return self.fail("img needs src and alt", tag);
            if (std.mem.eql(u8, tag, "meta") and !meta_content) return self.fail("meta needs content", tag);
            if (std.mem.eql(u8, tag, "style") and !style_type) return self.fail("style needs type", tag);
            if (!member(empty, tag)) {
                if (self.depth == self.frames.len) return self.fail("HTML nesting limit exceeded", tag);
                self.frames[self.depth] = .{ .name = tag };
                self.depth += 1;
            }
        }
        if (!root_seen or self.depth != 0) return self.fail("incomplete HTML document", "");
        for (self.header_refs.items) |ref| {
            if (!self.ids.contains(ref)) return self.fail("unresolved header reference", ref);
        }
    }
};

/// Validate the exact assembled page, including the selected layout and all
/// generated slots. A non-null finding is a content failure; OOM is an I/O
/// class failure. No external validator, network access, or subprocess.
pub fn check(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?Finding {
    var checker: Checker = .{ .bytes = bytes, .allocator = allocator };
    defer checker.ids.deinit(allocator);
    defer checker.header_refs.deinit(allocator);
    checker.run() catch |err| switch (err) {
        error.Invalid => return checker.failure.?,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return null;
}

test "whole-document checker rejects unsupported chrome and duplicate ids" {
    const prefix = doctype ++ "\n<html><head><title>Test</title></head><body><div>";
    const suffix = "</div></body></html>";
    try std.testing.expect((try check(std.testing.allocator, prefix ++ "<p id=\"one\">OK</p>" ++ suffix)) == null);
    for ([_][]const u8{
        "<nav>Bad</nav>",
        "<p id=\"one\">One</p><p id=\"one\">Two</p>",
        "<p aria-label=\"No\">Bad</p>",
        "<p><div>Bad</div></p>",
        "<table><thead><tr><th>Only header</th></tr></thead></table>",
        "<p>Bad &bogus;</p>",
        "<ol start=\"2\"><li>Two</li></ol>",
        "<blockquote></blockquote>",
        "<img src=\"photo.png\" alt=\"Photo\" usemap=\"#missing\">",
        "<table><tbody><tr><td headers=\"missing\">Bad</td></tr></tbody></table>",
    }) |fragment| {
        const page = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}", .{ prefix, fragment, suffix });
        defer std.testing.allocator.free(page);
        try std.testing.expect((try check(std.testing.allocator, page)) != null);
    }
    for ([_][]const u8{
        doctype ++ "&amp;<html><head><title>Test</title></head><body><p>OK</p></body></html>",
        doctype ++ "<html><head><title>Test</title>&amp;</head><body><p>OK</p></body></html>",
        doctype ++ "<html><head><title>Test</title></head><body><table>&amp;<tbody><tr><td>OK</td></tr></tbody></table></body></html>",
    }) |page| try std.testing.expect((try check(std.testing.allocator, page)) != null);
}
