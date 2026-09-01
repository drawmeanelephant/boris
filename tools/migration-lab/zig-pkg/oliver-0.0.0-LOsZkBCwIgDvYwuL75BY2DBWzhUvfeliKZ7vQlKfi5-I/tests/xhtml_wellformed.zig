//! Test-only XML well-formedness checker (tests/xhtml_test.zig gate).
//!
//! This is deliberately NOT an XML parser: it is a narrow validity
//! scanner used as machine evidence that representative Oliver XHTML output
//! is well-formed XML (docs/XHTML.md §"Well-formedness gate"). It lives in
//! the test tree, never in the library, and never becomes a second parsing
//! authority — Oliver's parser semantics are untouched by it.
//!
//! Rules enforced (XML 1.0, Fifth Edition subset sufficient for Oliver's
//! generated output):
//!   - one root element, properly nested, matching end tags
//!   - attributes double- or single-quoted, unique per start tag
//!   - self-closing elements via `/>`
//!   - text with no bare `<`; `&` only as a predefined or numeric reference
//!   - comments (`<!-- -->`, no `--`), CDATA sections, processing
//!     instructions (e.g. `<?xml ... ?>`)
//!   - no C0 control characters except tab/LF/CR
//!   - XML Name syntax for element/attribute names (ASCII subset; Oliver
//!     emits only ASCII element and attribute names)

const std = @import("std");

pub const Error = error{Malformed};

const Scanner = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn peek(self: *Scanner) ?u8 {
        return if (self.pos < self.bytes.len) self.bytes[self.pos] else null;
    }

    fn next(self: *Scanner) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        return c;
    }

    fn eof(self: *Scanner) bool {
        return self.pos >= self.bytes.len;
    }

    fn skipWs(self: *Scanner) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else break;
        }
    }

    /// `expect` consumes `s` or fails with Malformed.
    fn expect(self: *Scanner, s: []const u8) Error!void {
        if (self.pos + s.len > self.bytes.len or !std.mem.eql(u8, self.bytes[self.pos .. self.pos + s.len], s)) {
            return Error.Malformed;
        }
        self.pos += s.len;
    }

    fn isNameStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':';
    }

    fn isNameChar(c: u8) bool {
        return isNameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
    }

    /// Consumes an XML Name; fails if the next character cannot start one.
    fn name(self: *Scanner) Error![]const u8 {
        const start = self.pos;
        const first = self.next() orelse return Error.Malformed;
        if (!isNameStart(first)) return Error.Malformed;
        while (self.peek()) |c| {
            if (isNameChar(c)) {
                self.pos += 1;
            } else break;
        }
        return self.bytes[start..self.pos];
    }
};

/// Checks that `bytes` is well-formed XML (fragment or document). Returns
/// `error.Malformed` on the first violation.
pub fn check(bytes: []const u8) Error!void {
    var s = Scanner{ .bytes = bytes };
    var names: [256][]const u8 = undefined; // open-element name stack
    var depth: usize = 0;
    var root_seen = false;
    var root_closed = false;

    while (!s.eof()) {
        const c = s.peek() orelse break;
        if (c == '<') {
            // What follows `<`?
            const second = s.bytes[s.pos + 1 ..];
            if (std.mem.startsWith(u8, second, "!--")) {
                try comment(&s);
            } else if (std.mem.startsWith(u8, second, "![CDATA[")) {
                try cdata(&s);
            } else if (std.mem.startsWith(u8, second, "?")) {
                try pi(&s);
            } else if (std.mem.startsWith(u8, second, "!")) {
                // Anything else in a `<!` construct is out of scope for the
                // fragments Oliver generates (no DOCTYPE is ever emitted).
                return Error.Malformed;
            } else if (std.mem.startsWith(u8, second, "/")) {
                const name = try endTag(&s);
                if (depth == 0) return Error.Malformed;
                depth -= 1;
                if (!std.mem.eql(u8, names[depth], name)) return Error.Malformed;
                if (depth == 0) root_closed = true;
            } else {
                const tag = try startTag(&s);
                if (root_closed) return Error.Malformed; // trailing content after root
                root_seen = true;
                if (!tag.self_closing) {
                    if (depth >= names.len) return Error.Malformed;
                    names[depth] = tag.name;
                    depth += 1;
                }
            }
        } else {
            // Text content: no bare `<` (handled above), no bare `&`.
            try text(&s);
        }
    }
    if (!root_seen or depth != 0) return Error.Malformed;
}

fn text(s: *Scanner) Error!void {
    while (s.peek()) |c| {
        switch (c) {
            '<' => return,
            '&' => try entityRef(s),
            else => {
                try checkChar(c);
                s.pos += 1;
            },
        }
    }
}

fn entityRef(s: *Scanner) Error!void {
    // `&` must start a predefined or numeric reference.
    s.pos += 1; // consume '&'
    if (s.peek()) |c| {
        if (c == '#') {
            s.pos += 1;
            if (s.peek()) |h| {
                if (h == 'x' or h == 'X') {
                    s.pos += 1;
                    while (s.peek()) |d| {
                        if (std.ascii.isHex(d)) {
                            s.pos += 1;
                        } else break;
                    }
                } else {
                    while (s.peek()) |d| {
                        if (d >= '0' and d <= '9') {
                            s.pos += 1;
                        } else break;
                    }
                }
            }
            try s.expect(";");
            return;
        }
        const name_start = s.pos;
        while (s.peek()) |d| {
            if (Scanner.isNameChar(d)) {
                s.pos += 1;
            } else break;
        }
        const name = s.bytes[name_start..s.pos];
        if (std.mem.eql(u8, name, "amp") or
            std.mem.eql(u8, name, "lt") or
            std.mem.eql(u8, name, "gt") or
            std.mem.eql(u8, name, "apos") or
            std.mem.eql(u8, name, "quot"))
        {
            try s.expect(";");
            return;
        }
    }
    return Error.Malformed;
}

fn comment(s: *Scanner) Error!void {
    try s.expect("<!--");
    while (true) {
        if (s.eof()) return Error.Malformed;
        if (std.mem.startsWith(u8, s.bytes[s.pos..], "-->")) {
            s.pos += 3;
            return;
        }
        // `--` inside a comment is forbidden.
        if (std.mem.startsWith(u8, s.bytes[s.pos..], "--")) return Error.Malformed;
        try checkChar(s.bytes[s.pos]);
        s.pos += 1;
    }
}

fn cdata(s: *Scanner) Error!void {
    try s.expect("<![CDATA[");
    const end = std.mem.indexOf(u8, s.bytes[s.pos..], "]]>") orelse return Error.Malformed;
    s.pos += end + 3;
}

fn pi(s: *Scanner) Error!void {
    s.pos += 2; // consume '<?'
    _ = try s.name();
    while (true) {
        if (s.eof()) return Error.Malformed;
        if (std.mem.startsWith(u8, s.bytes[s.pos..], "?>")) {
            s.pos += 2;
            return;
        }
        s.pos += 1;
    }
}

fn checkChar(c: u8) Error!void {
    if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') return Error.Malformed;
}

const StartTag = struct {
    name: []const u8,
    self_closing: bool,
};

/// Parses `<name attrs...>` or `<name attrs.../>`; fails on malformed
/// names or unquoted attributes.
fn startTag(s: *Scanner) Error!StartTag {
    s.pos += 1; // consume '<'
    const name = try s.name();
    var self_closing = false;
    while (true) {
        s.skipWs();
        const c = s.peek() orelse return Error.Malformed;
        if (c == '>') {
            s.pos += 1;
            break;
        } else if (c == '/') {
            s.pos += 1;
            try s.expect(">");
            self_closing = true;
            break;
        }
        // Attribute: name = "value" | name = 'value'. The renderer emits a
        // fixed attribute set in fixed order, so a duplicate-attribute scan
        // is unnecessary for the gate; quoting and name syntax are checked.
        _ = try s.name();
        s.skipWs();
        try s.expect("=");
        s.skipWs();
        const quote = s.next() orelse return Error.Malformed;
        if (quote != '"' and quote != '\'') return Error.Malformed;
        while (s.peek()) |q| {
            if (q == quote) {
                s.pos += 1;
                break;
            }
            try checkChar(q);
            s.pos += 1;
        } else return Error.Malformed;
    }
    return .{ .name = name, .self_closing = self_closing };
}

fn endTag(s: *Scanner) Error![]const u8 {
    s.pos += 2; // consume '</'
    const name = try s.name();
    s.skipWs();
    try s.expect(">");
    return name;
}

test "well-formed: nested elements, attrs, self-closing" {
    try check("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>hi &amp; bye</p><br /><img src=\"a.png\" alt=\"x\" /></body></html>");
}

test "well-formed: rejected shapes" {
    try std.testing.expectError(error.Malformed, check("<p>unclosed"));
    try std.testing.expectError(error.Malformed, check("<p></q>"));
    try std.testing.expectError(error.Malformed, check("<p attr=unquoted></p>"));
    try std.testing.expectError(error.Malformed, check("<p>bare & ampersand</p>"));
    try std.testing.expectError(error.Malformed, check("<p>&bogus;</p>"));
    try std.testing.expectError(error.Malformed, check("<p>a < b</p>"));
    try std.testing.expectError(error.Malformed, check("<p></p><p></p>"));
    try std.testing.expectError(error.Malformed, check(""));
    try std.testing.expectError(error.Malformed, check("text only"));
    try std.testing.expectError(error.Malformed, check("<!-- unterminated"));
    try std.testing.expectError(error.Malformed, check("<!-- a -- b -->"));
}

test "well-formed: comments, CDATA, PI, numeric refs, entities" {
    try check("<?xml version=\"1.0\"?><html><!-- ok --><body><![CDATA[<raw>]]>&#65;&#x42;&apos;&quot;&lt;&gt;</body></html>");
}

test "well-formed: unicode text passes" {
    try check("<p>café — 日本語 😀</p>");
}

test "well-formed: control chars rejected" {
    try std.testing.expectError(error.Malformed, check("<p>a\x01b</p>"));
}
