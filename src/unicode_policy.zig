//! Ingest-time Unicode policy for content source.
//!
//! `utf8ValidateSlice` proves a file is well-formed. It says nothing about
//! whether the file contains code points that are invisible to every surface a
//! reviewer would use — the rendered page, view-source, and a text editor — but
//! fully visible to a model reading the output. Tag-block characters decode to
//! ASCII; zero-width runs spell words; bidi overrides reorder what a human sees
//! without changing what a parser reads.
//!
//! The policy runs here, on ingest, and not in any emitter. The same source
//! bytes fan out to HTML, the RAG corpus, the context bundle and `llms.txt`,
//! and those output paths escape correctly — none of these code points are
//! HTML-special, so a fix in an escaper would not touch this class. Checking
//! once at the door also means an emitter that does not exist yet inherits it.
//!
//! Boris is a documentation generator, so the cost of over-rejecting is real:
//! CJK, RTL scripts, combining marks, emoji ZWJ sequences and subdivision flags
//! are legitimate content. The tiers below are drawn to keep all of it.

const std = @import("std");

pub const Tier = enum {
    /// No legitimate use in documentation source. Rejected.
    reject,
    /// Invisible but genuinely dual-use. Reported, never mutated.
    warn,
};

pub const Finding = struct {
    tier: Tier,
    /// Byte offset of the first code point of the offending run.
    offset: usize,
    codepoint: u21,
    reason: Reason,

    pub const Reason = enum {
        control_character,
        noncharacter,
        deprecated_format_control,
        interlinear_annotation,
        bidi_override,
        unbalanced_bidi_isolate,
        tag_character_outside_flag,
        interior_byte_order_mark,
        zero_width_run,
        zero_width_between_ascii_letters,

        pub fn message(self: Reason) []const u8 {
            return switch (self) {
                .control_character => "control character is not allowed in content source",
                .noncharacter => "Unicode noncharacter is not allowed in content source",
                .deprecated_format_control => "deprecated Unicode format control is not allowed in content source",
                .interlinear_annotation => "interlinear annotation character is not intended for interchange",
                .bidi_override => "bidi embedding/override control can reorder text away from what a reviewer sees",
                .unbalanced_bidi_isolate => "bidi isolate is never closed, so its effect spills into later text",
                .tag_character_outside_flag => "Unicode tag character outside an emoji flag sequence carries hidden ASCII",
                .interior_byte_order_mark => "U+FEFF inside the document is a zero-width control; use U+2060 if a word joiner is intended",
                .zero_width_run => "run of zero-width characters",
                .zero_width_between_ascii_letters => "zero-width characters interleaved between ASCII letters",
            };
        }

        pub fn remediation(self: Reason) []const u8 {
            return switch (self) {
                .control_character, .noncharacter, .deprecated_format_control, .interlinear_annotation => "Remove the character; it has no rendered meaning",
                .bidi_override => "Use the bidi isolates U+2066-U+2069, or rely on the bidi algorithm, which handles Arabic and Hebrew without overrides",
                .unbalanced_bidi_isolate => "Close each isolate with U+2069 (POP DIRECTIONAL ISOLATE)",
                .tag_character_outside_flag => "Remove the tag characters; they are only valid as U+1F3F4 + tag letters + U+E007F",
                .interior_byte_order_mark => "Remove U+FEFF, or use U+2060 WORD JOINER",
                .zero_width_run, .zero_width_between_ascii_letters => "Remove the zero-width characters, or report this as a false positive if the text genuinely needs them",
            };
        }
    };
};

// --- classification --------------------------------------------------------

fn isC0Forbidden(c: u21) bool {
    if (c == '\t' or c == '\n' or c == '\r') return false;
    return c <= 0x08 or c == 0x0B or c == 0x0C or (c >= 0x0E and c <= 0x1F);
}

fn isC1OrDel(c: u21) bool {
    return c == 0x7F or (c >= 0x80 and c <= 0x9F);
}

fn isNoncharacter(c: u21) bool {
    if (c >= 0xFDD0 and c <= 0xFDEF) return true;
    return (c & 0xFFFE) == 0xFFFE;
}

fn isDeprecatedFormat(c: u21) bool {
    return c >= 0x206A and c <= 0x206F;
}

fn isInterlinear(c: u21) bool {
    return c >= 0xFFF9 and c <= 0xFFFB;
}

/// U+202A-U+202E: the embeddings and overrides Unicode deprecated in favour of
/// the isolates. RLO/LRO are the Trojan-Source primitive.
fn isBidiOverride(c: u21) bool {
    return c >= 0x202A and c <= 0x202E;
}

fn isBidiIsolateOpen(c: u21) bool {
    return c >= 0x2066 and c <= 0x2068;
}

fn isTagCharacter(c: u21) bool {
    return c >= 0xE0000 and c <= 0xE007F;
}

/// Zero-width and invisible characters that are also load-bearing in real
/// scripts: ZWNJ and ZWJ in Persian and Indic and in emoji sequences, ZWSP as a
/// CJK break opportunity, word joiner, soft hyphen. Identity cannot separate
/// the uses, so these are never rejected on sight.
fn isDualUseInvisible(c: u21) bool {
    return switch (c) {
        0x200B, 0x200C, 0x200D, 0x2060, 0x00AD => true,
        else => false,
    };
}

fn isAsciiLetter(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

const black_flag: u21 = 0x1F3F4;
const tag_terminator: u21 = 0xE007F;
const tag_letter_lo: u21 = 0xE0020;
const tag_letter_hi: u21 = 0xE007E;
const zero_width_run_threshold: usize = 3;

/// Scan `source` and append every finding. Never mutates and never allocates
/// beyond `out` — normalization is deliberately not done here: NFC is the only
/// safe form for this content (NFKC would rewrite `x²` to `x2` and `½` to
/// `1/2`), and a normalization pass belongs in its own change with its own
/// fixtures, not smuggled into a security check.
pub fn scan(gpa: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Finding)) !void {
    var sink: ListSink = .{ .gpa = gpa, .out = out };
    try scanInto(source, &sink);
}

const ListSink = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Finding),
    fn add(self: *ListSink, finding: Finding) !void {
        try self.out.append(self.gpa, finding);
    }
};

/// First rejection and first warning, without allocating.
///
/// `parser.parse` takes no allocator, so the ingest gate uses this form. The
/// list form exists for tooling that wants the whole picture.
pub const Summary = struct {
    rejection: ?Finding = null,
    warning: ?Finding = null,

    fn add(self: *Summary, finding: Finding) !void {
        switch (finding.tier) {
            .reject => if (self.rejection == null) {
                self.rejection = finding;
            },
            .warn => if (self.warning == null) {
                self.warning = finding;
            },
        }
    }
};

pub fn summarize(source: []const u8) Summary {
    var summary: Summary = .{};
    scanInto(source, &summary) catch {};
    return summary;
}

fn scanInto(source: []const u8, sink: anytype) !void {
    var view = std.unicode.Utf8View.init(source) catch return;
    var it = view.iterator();

    var isolate_depth: usize = 0;
    var first_open_isolate: ?usize = null;
    var prev_codepoint: u21 = 0;
    var zero_width_run: usize = 0;
    var zero_width_start: usize = 0;
    var zero_width_prev_letter = false;

    while (true) {
        const offset = it.i;
        const c = it.nextCodepoint() orelse break;

        if (isTagCharacter(c)) {
            _ = try scanTagSequence(&it, offset, c, prev_codepoint, sink);
            prev_codepoint = c;
            continue;
        }

        const reason: ?Finding.Reason =
            if (isC0Forbidden(c)) .control_character
            else if (isC1OrDel(c)) .control_character
            else if (isNoncharacter(c)) .noncharacter
            else if (isDeprecatedFormat(c)) .deprecated_format_control
            else if (isInterlinear(c)) .interlinear_annotation
            else if (isBidiOverride(c)) .bidi_override
            else if (c == 0xFEFF and offset != 0) .interior_byte_order_mark
            else null;

        if (reason) |r| {
            try sink.add(.{ .tier = .reject, .offset = offset, .codepoint = c, .reason = r });
        }

        if (isBidiIsolateOpen(c)) {
            if (isolate_depth == 0) first_open_isolate = offset;
            isolate_depth += 1;
        } else if (c == 0x2069 and isolate_depth > 0) {
            isolate_depth -= 1;
        }

        // Tier 3: density and adjacency, not identity.
        if (isDualUseInvisible(c)) {
            if (zero_width_run == 0) {
                zero_width_start = offset;
                zero_width_prev_letter = isAsciiLetter(prev_codepoint);
            }
            zero_width_run += 1;
        } else {
            try flushZeroWidth(zero_width_run, zero_width_start, zero_width_prev_letter and isAsciiLetter(c), sink);
            zero_width_run = 0;
        }

        prev_codepoint = c;
    }

    try flushZeroWidth(zero_width_run, zero_width_start, false, sink);

    if (isolate_depth > 0) {
        try sink.add(.{
            .tier = .reject,
            .offset = first_open_isolate orelse 0,
            .codepoint = 0x2066,
            .reason = .unbalanced_bidi_isolate,
        });
    }
}

fn flushZeroWidth(
    run: usize,
    start: usize,
    between_letters: bool,
    sink: anytype,
) !void {
    if (run == 0) return;
    // A single zero-width character between two ASCII letters is the smuggling
    // shape (`I<ZWSP>G<ZWSP>N`); ASCII does not need these characters. A long
    // run is suspicious wherever it appears.
    if (between_letters) {
        try sink.add(.{ .tier = .warn, .offset = start, .codepoint = 0x200B, .reason = .zero_width_between_ascii_letters });
    } else if (run >= zero_width_run_threshold) {
        try sink.add(.{ .tier = .warn, .offset = start, .codepoint = 0x200B, .reason = .zero_width_run });
    }
}

/// A tag character is legal only inside `U+1F3F4 (tag letters)+ U+E007F`, the
/// RGI subdivision-flag form that renders 🏴󠁧󠁢󠁳󠁣󠁴󠁿. Everything else is the ASCII-smuggling
/// channel. Returns true when the sequence was well formed.
fn scanTagSequence(
    it: *std.unicode.Utf8Iterator,
    offset: usize,
    first: u21,
    prev_codepoint: u21,
    sink: anytype,
) !bool {
    if (prev_codepoint != black_flag or first < tag_letter_lo or first > tag_letter_hi) {
        try sink.add(.{
            .tier = .reject,
            .offset = offset,
            .codepoint = first,
            .reason = .tag_character_outside_flag,
        });
        return false;
    }
    // Consume the rest of the sequence; it must be tag letters then U+E007F.
    while (true) {
        const at = it.i;
        const c = it.nextCodepoint() orelse {
            try sink.add(.{ .tier = .reject, .offset = offset, .codepoint = first, .reason = .tag_character_outside_flag });
            return false;
        };
        if (c == tag_terminator) return true;
        if (c < tag_letter_lo or c > tag_letter_hi) {
            it.i = at;
            try sink.add(.{ .tier = .reject, .offset = offset, .codepoint = first, .reason = .tag_character_outside_flag });
            return false;
        }
    }
}

/// The first rejection, if any. Callers that report one diagnostic per document
/// use this; callers that report everything walk the list.
pub fn firstRejection(findings: []const Finding) ?Finding {
    for (findings) |f| if (f.tier == .reject) return f;
    return null;
}

/// 1-based line and column of a byte offset, for diagnostics.
pub fn locate(source: []const u8, offset: usize) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var last_break: usize = 0;
    var i: usize = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            last_break = i + 1;
        }
    }
    return .{ .line = line, .column = @intCast(offset - last_break + 1) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn scanAlloc(source: []const u8) !std.ArrayList(Finding) {
    var out: std.ArrayList(Finding) = .empty;
    try scan(std.testing.allocator, source, &out);
    return out;
}

fn expectClean(source: []const u8) !void {
    var f = try scanAlloc(source);
    defer f.deinit(std.testing.allocator);
    if (f.items.len != 0) {
        std.debug.print("\nunexpected findings for {s}:\n", .{source});
        for (f.items) |item| std.debug.print("  U+{X:0>4} {s}\n", .{ item.codepoint, item.reason.message() });
    }
    try std.testing.expectEqual(@as(usize, 0), f.items.len);
}

fn expectReason(source: []const u8, want: Finding.Reason) !void {
    var f = try scanAlloc(source);
    defer f.deinit(std.testing.allocator);
    for (f.items) |item| {
        if (item.reason == want) return;
    }
    std.debug.print("\nexpected {s}, got:\n", .{@tagName(want)});
    for (f.items) |item| std.debug.print("  U+{X:0>4} {s}\n", .{ item.codepoint, @tagName(item.reason) });
    return error.ReasonNotFound;
}

test "ordinary documentation is untouched" {
    try expectClean("# Heading\n\nBody with tabs\tand newlines.\r\n");
    try expectClean("日本語のドキュメント and 中文文档");
    try expectClean("مرحبا بالعالم — Hebrew: שלום עולם");
    try expectClean("Combining marks: e\u{0301}gal, a\u{0300}");
    try expectClean("Emoji: 🎉 👍🏽 and the flag pair 🇯🇵");
}

test "emoji ZWJ sequences and subdivision flags survive — the carve-outs" {
    // Family: three ZWJ. A blanket zero-width reject would destroy this.
    try expectClean("👨\u{200D}👩\u{200D}👧\u{200D}👦");
    // Scotland: U+1F3F4 + tag letters + terminator.
    try expectClean("\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}");
    try expectClean("Wales \u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F} flag");
}

test "orthographic ZWNJ in Persian and Indic is not a finding" {
    try expectClean("می\u{200C}رود");
    try expectClean("हिन्\u{200C}दी");
}

test "tag characters outside a flag sequence are rejected — ASCII smuggling" {
    // "HI" smuggled through the tag block with no preceding flag.
    try expectReason("Title\u{E0048}\u{E0049}", .tag_character_outside_flag);
    // Tag letters after something that is not U+1F3F4.
    try expectReason("A\u{E0067}\u{E0062}\u{E007F}", .tag_character_outside_flag);
}

test "bidi overrides are rejected but RTL letters are not" {
    try expectReason("safe\u{202E}txet desrever", .bidi_override);
    try expectReason("\u{202A}embedded", .bidi_override);
    try expectClean("Arabic in prose: مرحبا, then back to English.");
}

test "an unclosed bidi isolate is rejected; a balanced one is fine" {
    try expectReason("start \u{2066}isolated", .unbalanced_bidi_isolate);
    try expectClean("start \u{2066}isolated\u{2069} end");
}

test "controls, noncharacters and interior BOM are rejected" {
    try expectReason("a\x01b", .control_character);
    try expectReason("a\x7Fb", .control_character);
    try expectReason("a\u{FDD0}b", .noncharacter);
    try expectReason("a\u{FFFE}b", .noncharacter);
    try expectReason("a\u{206B}b", .deprecated_format_control);
    try expectReason("a\u{FFF9}b", .interlinear_annotation);
    try expectReason("a\u{FEFF}b", .interior_byte_order_mark);
    // A BOM at offset 0 is the parser's existing, separate diagnostic.
    try expectClean("\u{FEFF}leading");
}

test "zero-width smuggling is warned on by shape, not identity" {
    var f = try scanAlloc("I\u{200B}G\u{200B}N\u{200B}O\u{200B}R\u{200B}E");
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.items.len > 0);
    try std.testing.expectEqual(Tier.warn, f.items[0].tier);
    try std.testing.expectEqual(Finding.Reason.zero_width_between_ascii_letters, f.items[0].reason);
    // Warnings are never rejections: this must not fail a build.
    try std.testing.expect(firstRejection(f.items) == null);

    // A long run is suspicious wherever it sits, ASCII neighbours or not.
    try expectReason("\u{65E5}\u{200B}\u{200B}\u{200B}\u{672C}", .zero_width_run);
    // A single zero-width character next to non-ASCII is left alone.
    try expectClean("日\u{200B}本");
}

test "locate maps an offset to line and column" {
    const src = "one\ntwo\nthree";
    const at = locate(src, 8);
    try std.testing.expectEqual(@as(u32, 3), at.line);
    try std.testing.expectEqual(@as(u32, 1), at.column);
}
