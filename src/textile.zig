//! Bounded Textile-to-Markdown body adapter.
//!
//! Normative: `docs/contracts/textile-compatibility.md`.
//! This module is pure: no filesystem, Apex, layout, graph, or process access.

const std = @import("std");

pub const adapter_identity = "boris-textile-adapter-v1";

pub const Diagnostic = struct {
    /// 1-based body-relative line.
    line: u32 = 1,
    /// 1-based byte column within the original Textile line.
    column: u32 = 1,
    message: []const u8,
};

pub const Result = struct {
    /// Allocator-owned on success. Empty when `diagnostic` is set.
    markdown: []const u8 = "",
    diagnostic: ?Diagnostic = null,

    pub fn isOk(self: Result) bool {
        return self.diagnostic == null;
    }
};

const ConvertError = error{InvalidTextile} || std.mem.Allocator.Error;

const PhysicalLine = struct {
    text: []const u8,
    next: usize,
    had_newline: bool,
};

fn readLine(body: []const u8, start: usize) PhysicalLine {
    var end = start;
    while (end < body.len and body[end] != '\n') : (end += 1) {}
    var text = body[start..end];
    const had_newline = end < body.len;
    if (had_newline and text.len > 0 and text[text.len - 1] == '\r') {
        text = text[0 .. text.len - 1];
    }
    return .{
        .text = text,
        .next = if (had_newline) end + 1 else end,
        .had_newline = had_newline,
    };
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn reject(diag_out: *?Diagnostic, line: u32, column: usize, message: []const u8) ConvertError {
    diag_out.* = .{
        .line = line,
        .column = @intCast(column),
        .message = message,
    };
    return error.InvalidTextile;
}

fn appendLineEnd(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: PhysicalLine) !void {
    if (line.had_newline) try out.append(allocator, '\n');
}

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isOpeningPunctuation(c: u8) bool {
    return c == '(' or c == '[' or c == '{' or c == '"' or c == '\'';
}

fn isClosingPunctuation(c: u8) bool {
    return c == '.' or c == ',' or c == ';' or c == ':' or c == '!' or
        c == '?' or c == ')' or c == ']' or c == '}' or c == '"' or c == '\'';
}

fn openerAt(text: []const u8, index: usize, delimiter: u8) bool {
    if (index >= text.len or text[index] != delimiter) return false;
    if (index > 0 and !isAsciiSpace(text[index - 1]) and !isOpeningPunctuation(text[index - 1])) return false;
    if (index + 1 >= text.len or isAsciiSpace(text[index + 1]) or text[index + 1] == delimiter) return false;
    return true;
}

fn phraseBoundaryAt(text: []const u8, index: usize) bool {
    return index == 0 or isAsciiSpace(text[index - 1]) or isOpeningPunctuation(text[index - 1]);
}

fn closingAt(text: []const u8, index: usize, delimiter: u8) bool {
    if (index >= text.len or text[index] != delimiter or index == 0) return false;
    if (isAsciiSpace(text[index - 1])) return false;
    return index + 1 == text.len or isAsciiSpace(text[index + 1]) or isClosingPunctuation(text[index + 1]);
}

fn findClosing(text: []const u8, start: usize, delimiter: u8) ?usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (closingAt(text, i, delimiter)) return i;
    }
    return null;
}

fn appendMarkdownByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, c: u8) !void {
    switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '\\', '`', '*', '_', '{', '}', '[', ']', '#', '+', '-', '!', '|', '~' => {
            try out.append(allocator, '\\');
            try out.append(allocator, c);
        },
        else => try out.append(allocator, c),
    }
}

fn appendMarkdownText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| try appendMarkdownByte(out, allocator, c);
}

fn appendHtmlText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '`' => try out.appendSlice(allocator, "&#96;"),
            '*' => try out.appendSlice(allocator, "&#42;"),
            '_' => try out.appendSlice(allocator, "&#95;"),
            '[' => try out.appendSlice(allocator, "&#91;"),
            ']' => try out.appendSlice(allocator, "&#93;"),
            else => try out.append(allocator, c),
        }
    }
}

fn looksLikeRawHtml(text: []const u8, index: usize) bool {
    if (text[index] != '<' or index + 1 >= text.len) return false;
    const next = text[index + 1];
    return std.ascii.isAlphabetic(next) or next == '/' or next == '!' or next == '?';
}

fn containsRawHtml(text: []const u8) bool {
    for (text, 0..) |c, i| {
        if (c == '<' and looksLikeRawHtml(text, i)) return true;
    }
    return false;
}

fn isFootnoteReference(text: []const u8, index: usize) bool {
    if (text[index] != '[' or index + 2 >= text.len) return false;
    var i = index + 1;
    if (!std.ascii.isDigit(text[i])) return false;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    return i < text.len and text[i] == ']';
}

fn completeUnsupportedPhrase(text: []const u8, index: usize, delimiter: u8) bool {
    if (!openerAt(text, index, delimiter)) return false;
    return findClosing(text, index + 1, delimiter) != null;
}

fn containsNestedModifier(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if ((c == '*' or c == '_' or c == '-' or c == '+' or c == '@') and openerAt(text, i, c)) return true;
        if (c == '"') {
            if (std.mem.indexOf(u8, text[i + 1 ..], "\":")) |_| return true;
        }
    }
    return false;
}

fn validDestination(destination: []const u8) bool {
    if (destination.len == 0) return false;
    for (destination) |c| {
        if (c <= 0x20 or c == 0x7f or c == '\\' or c == '"' or c == '\'' or
            c == '<' or c == '>' or c == '(' or c == ')' or c == '`') return false;
    }

    if (std.mem.startsWith(u8, destination, "http://")) return destination.len > "http://".len;
    if (std.mem.startsWith(u8, destination, "https://")) return destination.len > "https://".len;
    if (std.mem.startsWith(u8, destination, "mailto:")) return destination.len > "mailto:".len;
    if (std.mem.startsWith(u8, destination, "//")) return false;
    if (destination[0] == '/') return destination.len > 1;
    if (std.mem.startsWith(u8, destination, "./")) return destination.len > 2;
    if (std.mem.startsWith(u8, destination, "../")) return destination.len > 3;
    if (destination[0] == '#') return destination.len > 1;
    return false;
}

fn appendDestination(out: *std.ArrayList(u8), allocator: std.mem.Allocator, destination: []const u8) !void {
    for (destination) |c| {
        if (c == '&') {
            try out.appendSlice(allocator, "&amp;");
        } else {
            try out.append(allocator, c);
        }
    }
}

fn convertLink(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    index: usize,
    line_no: u32,
    base_column: usize,
    diag_out: *?Diagnostic,
) ConvertError!?usize {
    const quote_rel = std.mem.indexOfScalar(u8, text[index + 1 ..], '"') orelse return null;
    const quote = index + 1 + quote_rel;
    if (quote + 1 >= text.len or text[quote + 1] != ':') return null;

    const label = text[index + 1 .. quote];
    if (label.len == 0) return reject(diag_out, line_no, base_column + index, "Textile link label must not be empty");
    if (std.mem.indexOfScalar(u8, label, '(') != null or std.mem.indexOfScalar(u8, label, ')') != null) {
        return reject(diag_out, line_no, base_column + index, "Textile link titles and attributes are unsupported");
    }
    if (containsNestedModifier(label)) {
        return reject(diag_out, line_no, base_column + index, "nested Textile modifiers in link labels are unsupported");
    }

    const destination_start = quote + 2;
    var token_end = destination_start;
    while (token_end < text.len and !isAsciiSpace(text[token_end])) : (token_end += 1) {}
    var destination_end = token_end;
    while (destination_end > destination_start and
        std.mem.indexOfScalar(u8, ".,;!?", text[destination_end - 1]) != null)
    {
        destination_end -= 1;
    }
    const destination = text[destination_start..destination_end];
    if (!validDestination(destination)) {
        return reject(diag_out, line_no, base_column + destination_start, "Textile link destination is missing or unsafe");
    }

    try out.append(allocator, '[');
    try appendMarkdownText(out, allocator, label);
    try out.appendSlice(allocator, "](");
    try appendDestination(out, allocator, destination);
    try out.append(allocator, ')');
    return destination_end;
}

fn convertInline(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    line_no: u32,
    base_column: usize,
    diag_out: *?Diagnostic,
) ConvertError!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if (c < 0x20 and c != '\t') {
            return reject(diag_out, line_no, base_column + i, "control characters are unsupported in Textile bodies");
        }
        if (i + 1 < text.len and
            ((c == '{' and text[i + 1] == '{') or (c == '[' and text[i + 1] == '[')))
        {
            return reject(diag_out, line_no, base_column + i, "Boris macros, wiki links, and components are unsupported in Textile mode");
        }
        if (c == '<' and looksLikeRawHtml(text, i)) {
            return reject(diag_out, line_no, base_column + i, "raw HTML and executable components are unsupported in Textile mode");
        }
        if (c == '[' and isFootnoteReference(text, i)) {
            return reject(diag_out, line_no, base_column + i, "Textile footnotes and endnotes are unsupported");
        }

        if (i + 1 < text.len and phraseBoundaryAt(text, i) and
            ((c == '*' and text[i + 1] == '*') or
                (c == '_' and text[i + 1] == '_') or
                (c == '?' and text[i + 1] == '?') or
                (c == '=' and text[i + 1] == '=')))
        {
            return reject(diag_out, line_no, base_column + i, "this Textile phrase modifier is outside the compatibility subset");
        }
        if ((c == '%' or c == '^' or c == '~' or c == '!') and completeUnsupportedPhrase(text, i, c)) {
            return reject(diag_out, line_no, base_column + i, "this Textile phrase modifier is outside the compatibility subset");
        }

        if (c == '"') {
            if (try convertLink(out, allocator, text, i, line_no, base_column, diag_out)) |next| {
                i = next;
                continue;
            }
        }

        if ((c == '*' or c == '_' or c == '-' or c == '+' or c == '@') and openerAt(text, i, c)) {
            const close = findClosing(text, i + 1, c) orelse
                return reject(diag_out, line_no, base_column + i, "unclosed Textile phrase modifier");
            const inner = text[i + 1 .. close];
            if (inner.len == 0) return reject(diag_out, line_no, base_column + i, "Textile phrase modifier must not be empty");
            if (std.mem.indexOf(u8, inner, "{{") != null or std.mem.indexOf(u8, inner, "[[") != null) {
                return reject(diag_out, line_no, base_column + i, "Boris macros and wiki links are unsupported inside Textile phrases");
            }
            if (containsRawHtml(inner)) {
                return reject(diag_out, line_no, base_column + i, "raw HTML and executable components are unsupported inside Textile phrases");
            }
            if (inner[0] == '(' or inner[0] == '{' or inner[0] == '[') {
                return reject(diag_out, line_no, base_column + i, "Textile phrase attributes and CSS are unsupported");
            }
            if (containsNestedModifier(inner)) {
                return reject(diag_out, line_no, base_column + i, "nested Textile phrase modifiers are unsupported");
            }

            switch (c) {
                '*' => {
                    try out.appendSlice(allocator, "**");
                    try appendMarkdownText(out, allocator, inner);
                    try out.appendSlice(allocator, "**");
                },
                '_' => {
                    try out.append(allocator, '*');
                    try appendMarkdownText(out, allocator, inner);
                    try out.append(allocator, '*');
                },
                '-' => {
                    try out.appendSlice(allocator, "~~");
                    try appendMarkdownText(out, allocator, inner);
                    try out.appendSlice(allocator, "~~");
                },
                '+' => {
                    try out.appendSlice(allocator, "<ins>");
                    try appendHtmlText(out, allocator, inner);
                    try out.appendSlice(allocator, "</ins>");
                },
                '@' => {
                    if (std.mem.indexOfScalar(u8, inner, '`') != null) {
                        return reject(diag_out, line_no, base_column + i, "inline Textile code containing backticks is unsupported");
                    }
                    try out.append(allocator, '`');
                    try out.appendSlice(allocator, inner);
                    try out.append(allocator, '`');
                },
                else => unreachable,
            }
            i = close + 1;
            continue;
        }

        // Escape a leading decimal marker so plain Textile prose cannot become
        // a Markdown ordered list. Ordinary sentence punctuation is unchanged.
        if (c == '.' and i > 0 and i + 1 < text.len and isAsciiSpace(text[i + 1])) {
            var all_digits = true;
            for (text[0..i]) |prefix| {
                if (!std.ascii.isDigit(prefix)) {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) try out.append(allocator, '\\');
        }
        try appendMarkdownByte(out, allocator, c);
        i += 1;
    }
}

fn blockLineCount(body: []const u8, start: usize, end: usize) usize {
    var count: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const line = readLine(body, cursor);
        count += 1;
        cursor = line.next;
    }
    return count;
}

fn headingLevel(line: []const u8) ?u8 {
    if (line.len < 4 or line[0] != 'h' or line[2] != '.' or line[3] != ' ') return null;
    if (line[1] < '1' or line[1] > '6') return null;
    return line[1] - '0';
}

fn looksLikeHeadingSignature(line: []const u8) bool {
    if (line.len < 2 or line[0] != 'h' or !std.ascii.isDigit(line[1])) return false;
    if (line.len == 2) return true;
    return std.mem.indexOfScalar(u8, ".({[<>=", line[2]) != null;
}

fn looksLikeFootnoteBlock(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "fn")) return false;
    var i: usize = 2;
    if (i >= line.len or !std.ascii.isDigit(line[i])) return false;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    return i < line.len and line[i] == '.';
}

fn unsupportedBlockMessage(line: []const u8) ?[]const u8 {
    if (looksLikeHeadingSignature(line)) return "malformed heading or unsupported Textile heading attributes/CSS";
    if (std.mem.startsWith(u8, line, "bq..") or std.mem.startsWith(u8, line, "bq.:") or
        std.mem.startsWith(u8, line, "bq{") or std.mem.startsWith(u8, line, "bq(") or
        std.mem.startsWith(u8, line, "bq[") or std.mem.startsWith(u8, line, "bq<") or
        std.mem.startsWith(u8, line, "bq>") or std.mem.startsWith(u8, line, "bq="))
        return "extended/cited/attributed Textile block quotes are unsupported";
    if (std.mem.startsWith(u8, line, "p..") or std.mem.startsWith(u8, line, "p{") or
        std.mem.startsWith(u8, line, "p(") or std.mem.startsWith(u8, line, "p[") or
        std.mem.startsWith(u8, line, "p<") or std.mem.startsWith(u8, line, "p>") or
        std.mem.startsWith(u8, line, "p="))
        return "extended or attributed Textile paragraphs are unsupported";
    if (std.mem.startsWith(u8, line, "bc.") or std.mem.startsWith(u8, line, "bc..") or
        std.mem.startsWith(u8, line, "pre.") or std.mem.startsWith(u8, line, "pre..") or
        std.mem.startsWith(u8, line, "notextile.") or std.mem.startsWith(u8, line, "###."))
        return "this Textile block type is outside the compatibility subset";
    if (looksLikeFootnoteBlock(line)) return "Textile footnotes and endnotes are unsupported";
    if (line[0] == '|') return "Textile tables are unsupported";
    if (std.mem.startsWith(u8, line, "** ") or std.mem.startsWith(u8, line, "## ") or
        std.mem.startsWith(u8, line, "*# ") or std.mem.startsWith(u8, line, "#* "))
        return "nested and mixed Textile lists are unsupported";
    if (std.mem.startsWith(u8, line, "*(") or std.mem.startsWith(u8, line, "*{") or
        std.mem.startsWith(u8, line, "#[") or std.mem.startsWith(u8, line, "#(") or
        std.mem.startsWith(u8, line, "#{"))
        return "Textile list attributes and CSS are unsupported";
    if (std.mem.startsWith(u8, line, "- ")) return "Textile definition lists are unsupported";
    return null;
}

fn convertParagraph(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    start: usize,
    end: usize,
    start_line: u32,
    first_prefix_len: usize,
    diag_out: *?Diagnostic,
) ConvertError!void {
    var cursor = start;
    var line_no = start_line;
    var first = true;
    while (cursor < end) {
        const line = readLine(body, cursor);
        const prefix = if (first) first_prefix_len else 0;
        const text = line.text[prefix..];
        if (first and prefix > 0 and isBlank(text)) {
            return reject(diag_out, line_no, prefix + 1, "Textile paragraph must not be empty");
        }
        try convertInline(out, allocator, text, line_no, prefix + 1, diag_out);
        try appendLineEnd(out, allocator, line);
        cursor = line.next;
        line_no += 1;
        first = false;
    }
}

fn convertQuote(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    start: usize,
    end: usize,
    start_line: u32,
    diag_out: *?Diagnostic,
) ConvertError!void {
    var cursor = start;
    var line_no = start_line;
    var first = true;
    while (cursor < end) {
        const line = readLine(body, cursor);
        const prefix: usize = if (first) 4 else 0;
        const text = line.text[prefix..];
        if (first and isBlank(text)) return reject(diag_out, line_no, 5, "Textile block quote must not be empty");
        try out.appendSlice(allocator, "> ");
        try convertInline(out, allocator, text, line_no, prefix + 1, diag_out);
        try appendLineEnd(out, allocator, line);
        cursor = line.next;
        line_no += 1;
        first = false;
    }
}

fn convertList(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    start: usize,
    end: usize,
    start_line: u32,
    ordered: bool,
    diag_out: *?Diagnostic,
) ConvertError!void {
    const expected = if (ordered) "# " else "* ";
    var cursor = start;
    var line_no = start_line;
    var item_number: usize = 1;
    while (cursor < end) {
        const line = readLine(body, cursor);
        if (!std.mem.startsWith(u8, line.text, expected)) {
            if (unsupportedBlockMessage(line.text)) |message| return reject(diag_out, line_no, 1, message);
            return reject(diag_out, line_no, 1, "Textile list blocks require one flat item on every line");
        }
        const item = line.text[2..];
        if (isBlank(item)) return reject(diag_out, line_no, 3, "Textile list item must not be empty");
        if (ordered) {
            var marker_buffer: [32]u8 = undefined;
            const marker = std.fmt.bufPrint(&marker_buffer, "{d}. ", .{item_number}) catch unreachable;
            try out.appendSlice(allocator, marker);
            item_number += 1;
        } else {
            try out.appendSlice(allocator, "- ");
        }
        try convertInline(out, allocator, item, line_no, 3, diag_out);
        try appendLineEnd(out, allocator, line);
        cursor = line.next;
        line_no += 1;
    }
}

fn convertBlock(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    body: []const u8,
    start: usize,
    end: usize,
    start_line: u32,
    diag_out: *?Diagnostic,
) ConvertError!void {
    const first = readLine(body, start);

    if (headingLevel(first.text)) |level| {
        if (blockLineCount(body, start, end) != 1) {
            return reject(diag_out, start_line, 1, "Textile heading must be followed by a blank line");
        }
        const heading = first.text[4..];
        if (isBlank(heading)) return reject(diag_out, start_line, 5, "Textile heading must not be empty");
        try out.appendNTimes(allocator, '#', level);
        try out.append(allocator, ' ');
        try convertInline(out, allocator, heading, start_line, 5, diag_out);
        try appendLineEnd(out, allocator, first);
        return;
    }

    if (std.mem.startsWith(u8, first.text, "p. ")) {
        return convertParagraph(out, allocator, body, start, end, start_line, 3, diag_out);
    }
    if (std.mem.startsWith(u8, first.text, "bq. ")) {
        return convertQuote(out, allocator, body, start, end, start_line, diag_out);
    }
    if (std.mem.startsWith(u8, first.text, "* ")) {
        return convertList(out, allocator, body, start, end, start_line, false, diag_out);
    }
    if (std.mem.startsWith(u8, first.text, "# ")) {
        return convertList(out, allocator, body, start, end, start_line, true, diag_out);
    }

    if (unsupportedBlockMessage(first.text)) |message| {
        return reject(diag_out, start_line, 1, message);
    }
    if (std.mem.eql(u8, first.text, "p.") or std.mem.eql(u8, first.text, "bq.") or
        std.mem.eql(u8, first.text, "*") or std.mem.eql(u8, first.text, "#"))
    {
        return reject(diag_out, start_line, 1, "Textile block content must not be empty");
    }

    return convertParagraph(out, allocator, body, start, end, start_line, 0, diag_out);
}

/// Convert one already-frontmatter-split Textile body to Markdown.
pub fn toMarkdown(body: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!Result {
    if (!std.unicode.utf8ValidateSlice(body)) {
        return .{ .diagnostic = .{ .message = "Textile body is not valid UTF-8" } };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var diagnostic: ?Diagnostic = null;

    var cursor: usize = 0;
    var line_no: u32 = 1;
    var previous_list: ?bool = null; // false = unordered, true = ordered
    while (cursor < body.len) {
        const line = readLine(body, cursor);
        if (isBlank(line.text)) {
            if (line.had_newline) try out.append(allocator, '\n');
            cursor = line.next;
            line_no += 1;
            continue;
        }

        const block_start = cursor;
        const block_line = line_no;
        var block_end = cursor;
        var block_lines: u32 = 0;
        while (block_end < body.len) {
            const candidate = readLine(body, block_end);
            if (isBlank(candidate.text)) break;
            block_end = candidate.next;
            block_lines += 1;
        }

        const first = readLine(body, block_start).text;
        const current_list: ?bool = if (std.mem.startsWith(u8, first, "* "))
            false
        else if (std.mem.startsWith(u8, first, "# "))
            true
        else
            null;
        if (current_list) |ordered| {
            if (previous_list) |previous_ordered| {
                if (ordered != previous_ordered) {
                    out.deinit(allocator);
                    return .{ .diagnostic = .{
                        .line = block_line,
                        .column = 1,
                        .message = "adjacent unordered and ordered Textile list blocks require an intervening paragraph",
                    } };
                }
            }
            previous_list = ordered;
        } else {
            previous_list = null;
        }

        convertBlock(&out, allocator, body, block_start, block_end, block_line, &diagnostic) catch |err| switch (err) {
            error.InvalidTextile => {
                out.deinit(allocator);
                return .{ .diagnostic = diagnostic.? };
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        cursor = block_end;
        line_no += block_lines;
    }

    return .{ .markdown = try out.toOwnedSlice(allocator) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn readTestFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const io = std.testing.io;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn expectFixture(source_path: []const u8, expected_path: []const u8) !void {
    const gpa = std.testing.allocator;
    const source = try readTestFile(source_path, gpa);
    defer gpa.free(source);
    const expected = try readTestFile(expected_path, gpa);
    defer gpa.free(expected);

    const parser = @import("parser.zig");
    const parsed = parser.parse(source);
    try std.testing.expect(parsed.isOk());
    const result = try toMarkdown(parsed.doc.body, gpa);
    try std.testing.expect(result.isOk());
    defer gpa.free(result.markdown);
    try std.testing.expectEqualStrings(expected, result.markdown);
}

test "Textile compatibility fixtures match adapted Markdown goldens" {
    try expectFixture(
        "docs/contracts/fixtures/textile-compatibility/content/index.textile",
        "docs/contracts/fixtures/textile-compatibility/expected/adapted/index.md",
    );
    try expectFixture(
        "docs/contracts/fixtures/textile-compatibility/content/guides/intro.textile",
        "docs/contracts/fixtures/textile-compatibility/expected/adapted/guides/intro.md",
    );
}

test "Textile adapter rejects attributes malformed modifiers macros and unsafe links" {
    const cases = [_]struct { body: []const u8, needle: []const u8 }{
        .{ .body = "h2{color:red}. Styled\n", .needle = "attributes/CSS" },
        .{ .body = "A *strong phrase without a closer.\n", .needle = "unclosed" },
        .{ .body = "| A | table |\n", .needle = "tables" },
        .{ .body = "fn1. Note\n", .needle = "footnotes" },
        .{ .body = "{{include includes/a.md}}\n", .needle = "macros" },
        .{ .body = "A @{{include includes/a.md}}@ phrase.\n", .needle = "macros" },
        .{ .body = "A @<Aside>@ phrase.\n", .needle = "components" },
        .{ .body = "<Aside kind=\"tip\">x</Aside>\n", .needle = "components" },
        .{ .body = "\"bad\":javascript:alert\n", .needle = "unsafe" },
        .{ .body = "** nested\n", .needle = "nested" },
        .{ .body = "* bullet\n\n# number\n", .needle = "adjacent" },
    };
    for (cases) |case| {
        const result = try toMarkdown(case.body, std.testing.allocator);
        try std.testing.expect(!result.isOk());
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.?.message, case.needle) != null);
    }
}

test "Textile adapter escapes literal Markdown and HTML without changing ordinary prose" {
    const result = try toMarkdown("Plain # hash, [brackets], 5 < 7 & 8 > 3.\n", std.testing.allocator);
    try std.testing.expect(result.isOk());
    defer std.testing.allocator.free(result.markdown);
    try std.testing.expectEqualStrings(
        "Plain \\# hash, \\[brackets\\], 5 &lt; 7 &amp; 8 &gt; 3.\n",
        result.markdown,
    );
}

test "Textile adapter is deterministic" {
    const body = "h2. Title\n\nA *strong* _small_ +inserted+ phrase and \"link\":https://example.com/.\n";
    const a = try toMarkdown(body, std.testing.allocator);
    try std.testing.expect(a.isOk());
    defer std.testing.allocator.free(a.markdown);
    const b = try toMarkdown(body, std.testing.allocator);
    try std.testing.expect(b.isOk());
    defer std.testing.allocator.free(b.markdown);
    try std.testing.expectEqualStrings(a.markdown, b.markdown);
}
