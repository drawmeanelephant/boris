//! Shared typography pass (docs/SMARTY.md, docs/TEXTILE-PARITY.md §13 —
//! T15): straight quotes become curly by direction, `--` an em dash, a
//! space-surrounded `-` an en dash, `...` an ellipsis, a digit-adjacent
//! `x` the dimension sign, and the documented parenthesized symbols
//! (`(c)`/`(r)`/`(tm)` case-insensitive, `(1/4)`/`(1/2)`/`(3/4)`/`(o)`/
//! `(+/-)`) their Unicode equivalents.
//!
//! One implementation, two callers: Textile applies the pass to every
//! plain-text span (with the Textile-only `{...}` character-macro table
//! enabled), and Markdown's opt-in `smartypants` extension applies the
//! exact same pass with the macro table disabled — braces are ordinary
//! text in CommonMark (docs/SMARTY.md §1).
//!
//! HTML-looking `<...>` regions are copied verbatim (Hobix: HTML passes
//! through unescaped), and verbatim payloads (`@code@`, code blocks,
//! link/image src/alt/title, autolinks, wikilink targets/labels) never
//! pass through here. Returns the borrowed source slice when nothing
//! replaces (the fast path); only a span containing a replacement
//! allocates an arena copy — the same borrow-or-copy contract as the
//! Markdown entity resolver (docs/DOCUMENT-MODEL.md).

const std = @import("std");
const source = @import("source.zig");
const document = @import("document.zig");

pub const ParseError = error{OutOfMemory};

fn isWhitespaceByte(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// True when `b` is an ASCII letter, or false when `b` is null (a run's
/// edge never counts as a letter for the apostrophe rule).
fn isAsciiLetterOpt(b: ?u8) bool {
    if (b) |c| return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    return false;
}

fn isAsciiLetterByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

/// Case-insensitive prefix match of `pat` at `bytes[i]`.
fn matchesCi(bytes: []const u8, i: usize, pat: []const u8) bool {
    if (i + pat.len > bytes.len) return false;
    for (pat, 0..) |p, k| {
        const b = bytes[i + k];
        if (b >= 'A' and b <= 'Z') {
            if (b + 32 != p) return false;
        } else if (b != p) return false;
    }
    return true;
}

/// True when a text run needs the character-replacement pass: it contains
/// a straight quote, a hyphen, a period run, an opening paren, an
/// HTML-looking `<`, or a digit-adjacent `x` (the dimension-sign rule) —
/// plus a `{` when the Textile character-macro table is enabled (Textile
/// only; CommonMark smartypants never enables it). The `x` check is cheap
/// (one digit next to it, possibly through a single space) so plain words
/// like "example" do not force the slow path; the slow path's `changed`
/// flag discards the copy when nothing actually replaces.
fn hasTrigger(bytes: []const u8, char_macros: bool) bool {
    for (bytes, 0..) |b, i| {
        switch (b) {
            '"', '\'', '-', '.', '(', '<' => return true,
            '{' => if (char_macros) return true,
            'x' => {
                const left_ok = (i >= 2 and bytes[i - 1] == ' ' and bytes[i - 2] >= '0' and bytes[i - 2] <= '9') or
                    (i >= 1 and bytes[i - 1] >= '0' and bytes[i - 1] <= '9');
                const right_ok = (i + 2 < bytes.len and bytes[i + 1] == ' ' and bytes[i + 2] >= '0' and bytes[i + 2] <= '9') or
                    (i + 1 < bytes.len and bytes[i + 1] >= '0' and bytes[i + 1] <= '9');
                if (left_ok or right_ok) return true;
            },
            else => {},
        }
    }
    return false;
}

/// The byte at absolute source offset `p`, or null at the start of the
/// source. Text runs can begin mid-line after phrase delimiters, so quote
/// directionality and the en/dimension rules look at the surrounding
/// source bytes, not just the run.
fn srcByteAt(src: []const u8, p: usize) ?u8 {
    if (p >= src.len) return null;
    return src[p];
}

/// Applies the character replacements to a plain-text span. `char_macros`
/// enables the Textile `{...}` macro table (T20) — Textile only; CommonMark
/// smartypants copies braces literally. Returns the borrowed source slice
/// when nothing replaces (the fast path); only a span containing a
/// replacement allocates an arena copy.
pub fn replace(doc: *document.Document, span: source.Span, char_macros: bool) ParseError![]const u8 {
    const text = doc.text(span);
    if (!hasTrigger(text, char_macros)) return text;
    const src = doc.src.bytes;
    const abs = span.start;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(doc.allocator());
    var changed = false;
    var i: usize = 0;
    while (i < text.len) {
        const p = abs + i;
        switch (text[i]) {
            '"' => {
                // Opening when preceded by start-of-content, whitespace, or
                // an opening bracket; otherwise closing (Hobix + current
                // docs quote examples).
                const before = if (p == 0) null else srcByteAt(src, p - 1);
                const open = if (before) |b| switch (b) {
                    ' ', '\t', '\n', '\r', '(', '[', '{' => true,
                    else => false,
                } else true; // start of content opens
                try out.appendSlice(doc.allocator(), if (open) "\u{201C}" else "\u{201D}");
                changed = true;
                i += 1;
            },
            '\'' => {
                const before = if (p == 0) null else srcByteAt(src, p - 1);
                const after = srcByteAt(src, p + 1);
                if (isAsciiLetterOpt(before) and isAsciiLetterOpt(after)) {
                    try out.appendSlice(doc.allocator(), "\u{2019}"); // apostrophe
                } else if ((before == null or isWhitespaceByte(before.?)) and isAsciiLetterOpt(after)) {
                    try out.appendSlice(doc.allocator(), "\u{2018}"); // opening
                } else {
                    try out.appendSlice(doc.allocator(), "\u{2019}"); // closing/standalone
                }
                changed = true;
                i += 1;
            },
            '-' => {
                if (i + 1 < text.len and text[i + 1] == '-') {
                    try out.appendSlice(doc.allocator(), "\u{2014}"); // em dash
                    changed = true;
                    i += 2;
                } else {
                    const left: ?u8 = if (i == 0) (if (p == 0) null else srcByteAt(src, p - 1)) else text[i - 1];
                    const right: ?u8 = if (i + 1 < text.len) text[i + 1] else srcByteAt(src, p + 1);
                    if ((left != null and isWhitespaceByte(left.?)) and (right != null and isWhitespaceByte(right.?))) {
                        try out.appendSlice(doc.allocator(), "\u{2013}"); // en dash
                        changed = true;
                    } else {
                        try out.append(doc.allocator(), '-');
                    }
                    i += 1;
                }
            },
            '.' => {
                if (i + 2 < text.len and text[i + 1] == '.' and text[i + 2] == '.') {
                    try out.appendSlice(doc.allocator(), "\u{2026}"); // ellipsis
                    changed = true;
                    i += 3;
                } else {
                    try out.append(doc.allocator(), '.');
                    i += 1;
                }
            },
            'x' => {
                // Dimension sign between digits, with at most one space on
                // either side (current docs: "when placed between numbers").
                const left: ?u8 = if (i >= 2 and text[i - 1] == ' ') text[i - 2] else if (i >= 1) text[i - 1] else if (p == 0) null else srcByteAt(src, p - 1);
                const right: ?u8 = if (i + 2 < text.len and text[i + 1] == ' ') text[i + 2] else if (i + 1 < text.len) text[i + 1] else srcByteAt(src, p + 1);
                if (left != null and right != null and left.? >= '0' and left.? <= '9' and right.? >= '0' and right.? <= '9') {
                    try out.appendSlice(doc.allocator(), "\u{00D7}");
                    changed = true;
                } else {
                    try out.append(doc.allocator(), 'x');
                }
                i += 1;
            },
            '(' => {
                if (matchesCi(text, i, "(c)")) {
                    try out.appendSlice(doc.allocator(), "\u{00A9}");
                    changed = true;
                    i += 3;
                } else if (matchesCi(text, i, "(r)")) {
                    try out.appendSlice(doc.allocator(), "\u{00AE}");
                    changed = true;
                    i += 3;
                } else if (matchesCi(text, i, "(tm)")) {
                    try out.appendSlice(doc.allocator(), "\u{2122}");
                    changed = true;
                    i += 4;
                } else if (matchesCi(text, i, "(1/4)")) {
                    try out.appendSlice(doc.allocator(), "\u{00BC}");
                    changed = true;
                    i += 5;
                } else if (matchesCi(text, i, "(1/2)")) {
                    try out.appendSlice(doc.allocator(), "\u{00BD}");
                    changed = true;
                    i += 5;
                } else if (matchesCi(text, i, "(3/4)")) {
                    try out.appendSlice(doc.allocator(), "\u{00BE}");
                    changed = true;
                    i += 5;
                } else if (text[i + 1 ..].len >= 3 and text[i + 1] == 'o' and text[i + 2] == ')') {
                    try out.appendSlice(doc.allocator(), "\u{00B0}");
                    changed = true;
                    i += 3;
                } else if (text[i + 1 ..].len >= 4 and text[i + 1] == '+' and text[i + 2] == '/' and text[i + 3] == '-' and text[i + 4] == ')') {
                    try out.appendSlice(doc.allocator(), "\u{00B1}");
                    changed = true;
                    i += 5;
                } else {
                    try out.append(doc.allocator(), '(');
                    i += 1;
                }
            },
            '{' => {
                if (!char_macros) {
                    // CommonMark smartypants: braces are ordinary text; the
                    // macro table is Textile-only (docs/SMARTY.md §1).
                    try out.append(doc.allocator(), '{');
                    i += 1;
                    continue;
                }
                // Textile 2 "Character Replacements": the default `{...}`
                // macro table — the documented forms, each with its mirrored
                // order where shown, map to a single character. Every other
                // `{...}` shape stays literal (the general letter+accent
                // pattern beyond the documented examples is deferred;
                // docs/TEXTILE-PARITY.md §18). The phrase scanner keeps the
                // brace region whole (operators at a brace edge are not
                // recognized), so the full `{...}` reaches this pass.
                var macro_len: usize = 0;
                var macro_out: []const u8 = "";
                if (std.mem.startsWith(u8, text[i..], "{c|}") or std.mem.startsWith(u8, text[i..], "{|c}")) {
                    macro_len = 4;
                    macro_out = "\u{00A2}"; // cent
                } else if (std.mem.startsWith(u8, text[i..], "{L-}") or std.mem.startsWith(u8, text[i..], "{-L}")) {
                    macro_len = 4;
                    macro_out = "\u{00A3}"; // pound
                } else if (std.mem.startsWith(u8, text[i..], "{Y=}") or std.mem.startsWith(u8, text[i..], "{=Y}")) {
                    macro_len = 4;
                    macro_out = "\u{00A5}"; // yen
                } else if (std.mem.startsWith(u8, text[i..], "{A'}") or std.mem.startsWith(u8, text[i..], "{'A}")) {
                    macro_len = 4;
                    macro_out = "\u{00C1}"; // A acute
                } else if (std.mem.startsWith(u8, text[i..], "{a\"}") or std.mem.startsWith(u8, text[i..], "{\"a}")) {
                    macro_len = 4;
                    macro_out = "\u{00E4}"; // a diaeresis
                } else if (std.mem.startsWith(u8, text[i..], "{1/4}")) {
                    macro_len = 5;
                    macro_out = "\u{00BC}"; // one quarter
                } else if (std.mem.startsWith(u8, text[i..], "{*}")) {
                    macro_len = 3;
                    macro_out = "\u{2022}"; // bullet
                } else if (std.mem.startsWith(u8, text[i..], "{:)}")) {
                    macro_len = 4;
                    macro_out = "\u{263A}"; // smiley
                } else if (std.mem.startsWith(u8, text[i..], "{:(}")) {
                    macro_len = 4;
                    macro_out = "\u{2639}"; // frowny
                }
                if (macro_len > 0) {
                    try out.appendSlice(doc.allocator(), macro_out);
                    changed = true;
                    i += macro_len;
                } else {
                    try out.append(doc.allocator(), '{');
                    i += 1;
                }
            },
            '<' => {
                // HTML-looking region: `<` + a letter or `/`, copied verbatim
                // through the closing `>` (no replacements inside tags). A
                // bare `<` stays literal text and scanning continues.
                if (i + 1 < text.len and (isAsciiLetterByte(text[i + 1]) or text[i + 1] == '/')) {
                    var j = i + 1;
                    while (j < text.len and text[j] != '>') : (j += 1) {}
                    if (j < text.len) {
                        try out.appendSlice(doc.allocator(), text[i .. j + 1]);
                        i = j + 1;
                        continue;
                    }
                }
                try out.append(doc.allocator(), '<');
                i += 1;
            },
            else => {
                try out.append(doc.allocator(), text[i]);
                i += 1;
            },
        }
    }
    if (!changed) return text;
    return out.toOwnedSlice(doc.allocator());
}
