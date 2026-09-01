//! Cooklang frontend.
//!
//! Parses `*.cook` recipes into a typed `Recipe` semantic model — not the
//! Markdown/Textile `document.Document` IR — because recipe semantics
//! (ingredients, quantities, units, cookware, timers, preparations,
//! recipe references, steps, sections, notes, metadata) must survive
//! parsing as typed data. The model reuses Oliver's infrastructure:
//! `source.Span`/`source.Source` for exact byte positions, the
//! diagnostic type, arena ownership, byte borrowing, `source.Lines`,
//! and the unicode predicates.
//!
//! Sources of truth (clean-room): the official Cooklang specification
//! (https://cooklang.org/docs/spec/), the `cooklang/spec` repository at
//! commit `6c4788644004e604ae1da110af6d2400e3c9c7b0` (the EBNF — marked
//! WIP/outdated — the Released proposals 0005 note-blocks and 0006
//! sections, conventions, and the canonical test corpus), and the
//! official examples. Full provenance and every chosen behavior are
//! recorded in docs/COOKLANG.md and docs/CLEANROOM.md session 21.
//!
//! Chosen behaviors (pinned by tests; see docs/COOKLANG.md §4):
//! - A token's multiword name runs to the first `{` on the line, but the
//!   region stops early at a following token marker (`@`/`#`/`~`), at
//!   P-category punctuation, and at non-`-`/`.`/`/` boundaries — so the
//!   spec's own `@salt and @ground black pepper{}` parses as two
//!   ingredients (the raw EBNF would name the whole run). With no `{`,
//!   the token is single-word (first word, ending at Unicode whitespace
//!   or P-category punctuation — symbols stay in names, per the corpus's
//!   `@🧂`).
//! - Invalid token shapes degrade to literal text (the corpus's invalid
//!   tests), never errors: the marker must be followed by a non-
//!   whitespace character, braces must close on the line, and a single
//!   word must start with a word character.
//! - `--` line comments run to end of line and `[- ... -]` block
//!   comments may span lines; both are removed from the semantic tree.
//!   An unclosed `[-` degrades to literal text.
//! - Steps are blank-line-separated paragraphs; continuation lines join
//!   with a single space (canonical), a line ending in `\` forces a
//!   line break, and multi-line steps merge their text runs.
//! - Notes (a paragraph whose first line starts with `>`) and section
//!   titles are plain text — never scanned for tokens.
//! - YAML front matter is recognized at its boundaries (both fences at
//!   the very start of the file) and the raw payload is preserved with
//!   exact spans. By default Oliver does not parse YAML; with
//!   `ParseOptions.frontmatter` on, the shared pre-pass
//!   (src/frontmatter.zig) additionally parses the payload into
//!   `Recipe.metadata` under a documented bounded subset
//!   (docs/FRONTMATTER.md) — never faked, out-of-subset payloads stay
//!   raw.

const std = @import("std");
const source = @import("source.zig");
const diagnostic = @import("diagnostic.zig");
const unicode = @import("unicode.zig");
const frontmatter = @import("frontmatter.zig");

pub const ParseError = error{ OutOfMemory, InputTooLarge };

// ---------------------------------------------------------------------------
// The typed Recipe model.
// ---------------------------------------------------------------------------

/// A derived numeric view of a quantity. The source text is always
/// preserved (`quantity`); this exists only for pure canonical numeric
/// forms (`2`, `1.5`, `1/2`, mixed `1 1/2`) so the conformance harness
/// and scaling can compare numerically without ever coercing the text.
/// A mixed number is stored as its equivalent (not necessarily
/// reduced) improper fraction — there is no mixed-number output form.
pub const Quantity = union(enum) {
    int: i64,
    decimal: f64,
    fraction: Fraction,
};

pub const Fraction = struct {
    num: u32,
    den: u32,
};

pub const Ingredient = struct {
    /// The semantic name (borrowed source bytes; multiword names are
    /// trimmed and run to the first `{` on the line).
    name: []const u8,
    name_span: source.Span,
    /// Source text inside `{}` before `%`, trimmed; null when the token
    /// carried no braces at all. Canonical defaults (`"some"` for
    /// ingredients, `1` for cookware, `""` for timers) are applied by
    /// the conformance harness, not the model.
    quantity: ?[]const u8,
    quantity_span: source.Span,
    /// Source text after `%`, trimmed; null when absent.
    units: ?[]const u8,
    units_span: source.Span,
    /// Numeric view of `quantity`, when it is a pure canonical form.
    numeric: ?Quantity,
    /// Shorthand preparation `(peeled and finely chopped)` after the
    /// braces; null when absent. Opaque plain text.
    preparation: ?[]const u8,
    preparation_span: source.Span,
    /// True when the name begins with `./`, `../`, or `/` — a reference
    /// to another recipe. Oliver never resolves it (that is a consumer
    /// concern).
    is_recipe_reference: bool,
    /// The whole token: marker through the closing `}` (and `)`).
    span: source.Span,
};

pub const Cookware = struct {
    name: []const u8,
    name_span: source.Span,
    quantity: ?[]const u8,
    quantity_span: source.Span,
    numeric: ?Quantity,
    span: source.Span,
};

pub const Timer = struct {
    /// Empty for the unnamed form `~{25%minutes}`.
    name: []const u8,
    name_span: source.Span,
    quantity: ?[]const u8,
    quantity_span: source.Span,
    units: ?[]const u8,
    units_span: source.Span,
    numeric: ?Quantity,
    span: source.Span,
};

pub const TextPart = struct {
    /// The semantic text value: an arena-owned copy (line joins replace
    /// the newline with a space; comments are omitted).
    text: []const u8,
    /// The full source extent of the run, including any joined or
    /// commented bytes inside it.
    span: source.Span,
};

pub const Part = union(enum) {
    text: TextPart,
    ingredient: Ingredient,
    cookware: Cookware,
    timer: Timer,
    line_break: source.Span,
};

pub const Step = struct {
    parts: []Part,
    /// The paragraph's full source extent (first content byte through
    /// the last content byte, including comments and joins inside).
    span: source.Span,
};

pub const Note = struct {
    /// The note content with `>` prefixes (and one following space)
    /// stripped and lines joined by spaces (arena-owned). Plain text —
    /// never scanned for tokens (proposal 0005).
    text: []const u8,
    span: source.Span,
};

pub const Section = struct {
    /// The section title (borrowed source bytes; leading/trailing `=`s
    /// and whitespace stripped). Plain text — never scanned for tokens
    /// (proposal 0006).
    name: []const u8,
    name_span: source.Span,
    /// The header line's extent.
    span: source.Span,
    /// The steps (and notes) under this header, up to the next header
    /// or end of file.
    blocks: []Block,
};

pub const Block = union(enum) {
    step: Step,
    section: Section,
    note: Note,
};

pub const Frontmatter = struct {
    /// The raw YAML payload between the fences (a borrowed source
    /// slice, including the trailing newline of the last content line),
    /// never parsed.
    raw: []const u8,
    /// The whole front matter block, both fences included.
    span: source.Span,
};

/// A parsed recipe. All memory is owned by `arena` (except text payloads,
/// which borrow from the input); `deinit` releases it in one step.
pub const Recipe = struct {
    source: source.Source,
    arena: std.heap.ArenaAllocator,
    frontmatter: ?Frontmatter = null,
    /// Parsed front matter metadata when `ParseOptions.frontmatter` is on
    /// and the recipe opens with a fence; null otherwise — the parsed view
    /// beside `frontmatter.raw` (docs/FRONTMATTER.md §8). Arena-owned.
    metadata: ?frontmatter.Metadata = null,
    blocks: []Block = &.{},

    pub fn allocator(self: *Recipe) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Recipe) void {
        self.arena.deinit();
    }
};

pub const ParseOptions = struct {
    /// Front matter handling: `.none` (default) keeps the boundary-only
    /// behavior — `---` fences sniffed at index 0, raw payload + exact
    /// spans, never parsed. `.yaml` / `.toml` additionally parse the
    /// payload into `Recipe.metadata` under the bounded subset
    /// (docs/FRONTMATTER.md §8).
    frontmatter: frontmatter.Option = .none,
};

pub const ParseResult = struct {
    recipe: Recipe,
    diagnostics: []const diagnostic.Diagnostic = &.{},

    pub fn deinit(self: *ParseResult) void {
        self.recipe.deinit();
    }
};

/// Parses `input` as Cooklang into a typed Recipe. The input bytes are
/// borrowed by text payloads and must outlive the result.
///
/// The public entry point is `oliver.cooklang.parse`; see docs/COOKLANG.md
/// for the full contract.
pub fn parse(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) ParseError!ParseResult {
    if (input.len > source.max_input_len) return error.InputTooLarge;

    var recipe = Recipe{
        .source = .{ .bytes = input },
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer recipe.deinit();
    const a = recipe.allocator();

    // Diagnostics are arena-owned with the recipe so every appender (the
    // front matter pre-pass and the parser) uses one allocator.
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;

    // Front matter: the shared pre-pass (docs/FRONTMATTER.md). Cooklang's
    // boundary behavior is always on — `.none` still sniffs `---` (raw
    // payload + exact spans, never parsed); `.yaml`/`.toml` additionally
    // parse into `Recipe.metadata`. The source is rebound to the clean
    // body; `frontmatter.raw`/`span` keep referencing `input`, which
    // outlives the result.
    const fm_mode: frontmatter.Option = if (options.frontmatter == .none) .yaml else options.frontmatter;
    const fm = try frontmatter.preprocess(a, input, fm_mode, options.frontmatter != .none, &diags);
    recipe.source = .{ .bytes = fm.body };

    var parser = Parser{
        .src = recipe.source,
        .a = a,
        .top = std.ArrayList(Block).empty,
        .section_blocks = std.ArrayList(Block).empty,
        .diags = &diags,
    };

    // Blocks: blank lines separate paragraphs. A paragraph whose first
    // line starts with `>` is a note; a line starting with `=` is a
    // section header; anything else is a step.
    var lines = source.Lines.init(fm.body);
    var para = std.ArrayList(source.Span).empty;
    while (lines.next()) |line| {
        if (isBlank(line.text)) {
            if (para.items.len > 0) {
                try appendParagraph(&parser, para.items);
                para.clearRetainingCapacity();
            }
            continue;
        }
        if (line.text.len > 0 and line.text[0] == '=') {
            if (para.items.len > 0) {
                try appendParagraph(&parser, para.items);
                para.clearRetainingCapacity();
            }
            try parser.openSection(line);
            continue;
        }
        try para.append(a, line.contentSpan());
    }
    if (para.items.len > 0) try appendParagraph(&parser, para.items);

    // Finalize an open section (no-op when none is open).
    try parser.finishSection();

    recipe.frontmatter = if (fm.block) |b| .{ .raw = b.raw, .span = b.span } else null;
    recipe.metadata = if (fm.block) |b| b.metadata else null;
    recipe.blocks = try parser.top.toOwnedSlice(a);
    return .{ .recipe = recipe, .diagnostics = try diags.toOwnedSlice(a) };
}

// ---------------------------------------------------------------------------
// Parser state.
// ---------------------------------------------------------------------------

const Parser = struct {
    src: source.Source,
    a: std.mem.Allocator,
    /// Top-level blocks (steps, notes, sections).
    top: std.ArrayList(Block),
    /// The open section's blocks; empty when no section is open.
    section_blocks: std.ArrayList(Block),
    /// Structured diagnostics (allocation errors surface as ParseError).
    diags: *std.ArrayList(diagnostic.Diagnostic),

    /// True while a section header has been seen (even if it holds no
    /// blocks yet).
    section_open: bool = false,

    /// The most recent section header (for finalizing).
    pending_section: ?Section = null,

    /// Appends `block` to the open section, or to the top level.
    fn append(self: *Parser, block: Block) ParseError!void {
        if (self.section_open or self.section_blocks.items.len > 0) {
            try self.section_blocks.append(self.a, block);
        } else {
            try self.top.append(self.a, block);
        }
    }

    /// Closes the open section, appending it to the top level.
    fn finishSection(self: *Parser) ParseError!void {
        if (self.pending_section) |*sec| {
            sec.blocks = try self.section_blocks.toOwnedSlice(self.a);
            try self.top.append(self.a, .{ .section = sec.* });
            self.section_blocks = std.ArrayList(Block).empty;
            self.section_open = false;
            self.pending_section = null;
        }
    }

    /// Opens a new section from a header line, closing any open one.
    /// Grammar (proposal 0006): `section title = { '=' }-, { text item },
    /// { '=' };` — the number of `=`s does not matter and the closing
    /// `=`s are optional.
    fn openSection(self: *Parser, line: source.Line) ParseError!void {
        try self.finishSection();
        const content = line.text;
        var i: usize = 0;
        while (i < content.len and content[i] == '=') : (i += 1) {}
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
        const name_start = i;
        // Strip trailing whitespace, then a trailing `=` run, then
        // trailing whitespace again, so `== Filling ==` -> `Filling`.
        var j = content.len;
        while (j > name_start and (content[j - 1] == ' ' or content[j - 1] == '\t')) : (j -= 1) {}
        while (j > name_start and content[j - 1] == '=') : (j -= 1) {}
        while (j > name_start and (content[j - 1] == ' ' or content[j - 1] == '\t')) : (j -= 1) {}
        self.pending_section = .{
            .name = content[name_start..j],
            .name_span = .{ .start = @intCast(line.start + name_start), .end = @intCast(line.start + j) },
            .span = .{ .start = @intCast(line.start), .end = @intCast(line.end) },
            .blocks = &.{},
        };
        self.section_open = true;
    }
};

fn isBlank(text: []const u8) bool {
    for (text) |b| {
        if (b != ' ' and b != '\t') return false;
    }
    return true;
}

fn isAsciiWs(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// Emits a warning diagnostic at `span`. Only genuinely malformed
/// structure warns (unclosed delimiters); corpus-pinned near-misses stay
/// silent literal text (docs/COOKLANG.md §Diagnostics).
fn emitWarning(parser: *Parser, code: []const u8, span: source.Span, message: []const u8) ParseError!void {
    const lc = parser.src.lineCol(span.start);
    try parser.diags.append(parser.a, .{
        .severity = .warning,
        .code = code,
        .offset = span.start + 1,
        .line = lc.line,
        .column = lc.column,
        .span = span,
        .message = message,
    });
}

const Trimmed = struct { s: usize, e: usize };

/// The trimmed `[s, e)` region of `bytes[start..end]` (ASCII space/tab).
fn trimRegion(bytes: []const u8, start: usize, end: usize) Trimmed {
    var s = start;
    var e = end;
    while (s < e and isAsciiWs(bytes[s])) s += 1;
    while (e > s and isAsciiWs(bytes[e - 1])) e -= 1;
    return .{ .s = s, .e = e };
}

// ---------------------------------------------------------------------------
// Paragraph assembly: steps, notes.
// ---------------------------------------------------------------------------

/// Dispatches a paragraph (a run of content lines) to a step or a note.
fn appendParagraph(parser: *Parser, para: []const source.Span) ParseError!void {
    if (parser.src.bytes[para[0].start] == '>') {
        try parser.append(.{ .note = try buildNote(parser, para) });
    } else if (try buildStep(parser, para)) |step| {
        try parser.append(.{ .step = step });
    }
}

/// A note: `>` (and one following space) stripped from each line, lines
/// joined by a single space. The first line must start with `>` (checked
/// by the caller); later lines may or may not carry the marker.
fn buildNote(parser: *Parser, para: []const source.Span) ParseError!Note {
    const bytes = parser.src.bytes;
    var buf = std.ArrayList(u8).empty;
    for (para, 0..) |span, idx| {
        var start: usize = span.start;
        if (start < span.end and bytes[start] == '>') {
            start += 1;
            if (start < span.end and (bytes[start] == ' ' or bytes[start] == '\t')) start += 1;
        }
        if (idx > 0) try buf.append(parser.a, ' ');
        try buf.appendSlice(parser.a, bytes[start..span.end]);
    }
    const text = try buf.toOwnedSlice(parser.a);
    return .{
        .text = text,
        .span = .{ .start = @intCast(para[0].start), .end = @intCast(para[para.len - 1].end) },
    };
}

/// One text run within a paragraph: its source extent and its extent in
/// the paragraph's text buffer (the value is materialized at the end).
const TextMeta = struct {
    span: source.Span,
    part_index: usize,
    buf_start: usize,
    buf_end: usize,
};

const ScanRes = struct {
    next_line: usize,
    next_offset: ?u32,
    /// Whether this line emitted any content.
    emitted: bool,
    /// Whether this line ended with a forced line break (`\`).
    broke: bool,
    /// The `\` byte's span when `broke`.
    break_span: source.Span = .{ .start = 0, .end = 0 },
};

/// Paragraph-level scan state for one step.
const ParaState = struct {
    a: std.mem.Allocator,
    src: source.Source,
    /// Accumulated text values (join spaces included).
    buf: std.ArrayList(u8),
    /// Typed parts; text parts carry a placeholder value until
    /// materialize().
    parts: std.ArrayList(Part),
    metas: std.ArrayList(TextMeta),
    /// Index into `parts` of the open text part, or null.
    text_index: ?usize = null,
    /// A join space is pending before the next emitted content.
    pending_join: bool = false,
    /// A forced line break is pending before the next emitted content.
    pending_break: bool = false,
    break_span: source.Span = .{ .start = 0, .end = 0 },
    /// Byte offsets of every `-]` in the paragraph (precomputed so a
    /// `[-` lookahead is amortized O(1), never a rescan).
    closes: []const u32 = &.{},
    close_cursor: usize = 0,
    /// The byte offset of the current line boundary (the content end of
    /// the line that just finished), for synthetic join spans.
    join_pos: usize = 0,
    /// Diagnostics sink (shared with the owning Parser).
    diags: *std.ArrayList(diagnostic.Diagnostic),

    /// Emits a warning diagnostic at `span` (line/column resolved from
    /// the source).
    fn warn(self: *ParaState, code: []const u8, span: source.Span, message: []const u8) ParseError!void {
        const lc = self.src.lineCol(span.start);
        try self.diags.append(self.a, .{
            .severity = .warning,
            .code = code,
            .offset = span.start + 1,
            .line = lc.line,
            .column = lc.column,
            .span = span,
            .message = message,
        });
    }

    fn closeText(self: *ParaState) void {
        self.text_index = null;
    }

    /// Applies a pending break or join before the next emitted part.
    fn emitStart(self: *ParaState) ParseError!void {
        if (self.pending_break) {
            self.pending_break = false;
            self.closeText();
            try self.parts.append(self.a, .{ .line_break = self.break_span });
        } else if (self.pending_join) {
            self.pending_join = false;
            try self.appendJoin();
        }
    }

    /// Appends the synthetic join space between lines, merging into the
    /// open text part when there is one.
    fn appendJoin(self: *ParaState) ParseError!void {
        const pos: u32 = @intCast(self.join_pos);
        if (self.text_index) |ti| {
            try self.buf.append(self.a, ' ');
            self.metas.items[ti].buf_end = self.buf.items.len;
        } else {
            const mi = self.metas.items.len;
            self.text_index = mi;
            try self.metas.append(self.a, .{ .span = .{ .start = pos, .end = pos }, .part_index = self.parts.items.len, .buf_start = self.buf.items.len, .buf_end = 0 });
            try self.parts.append(self.a, .{ .text = .{ .text = "", .span = .{ .start = pos, .end = pos } } });
            try self.buf.append(self.a, ' ');
            self.metas.items[mi].buf_end = self.buf.items.len;
        }
    }

    /// Appends source bytes as text, opening or extending the open text
    /// part. Callers must guarantee `start < end`. Text values and spans
    /// live in `metas` until materialize() patches the parts.
    fn appendText(self: *ParaState, start: usize, end: usize) ParseError!void {
        try self.emitStart();
        if (self.text_index) |ti| {
            self.metas.items[ti].span.end = @intCast(end);
        } else {
            const mi = self.metas.items.len;
            self.text_index = mi;
            try self.metas.append(self.a, .{ .span = .{ .start = @intCast(start), .end = @intCast(end) }, .part_index = self.parts.items.len, .buf_start = self.buf.items.len, .buf_end = 0 });
            try self.parts.append(self.a, .{ .text = .{ .text = "", .span = .{ .start = @intCast(start), .end = @intCast(end) } } });
        }
        try self.buf.appendSlice(self.a, self.src.bytes[start..end]);
        self.metas.items[self.text_index.?].buf_end = self.buf.items.len;
    }

    fn appendIngredient(self: *ParaState, t: Token) ParseError!void {
        try self.emitStart();
        self.closeText();
        try self.parts.append(self.a, .{ .ingredient = .{
            .name = t.name,
            .name_span = t.name_span,
            .quantity = t.quantity,
            .quantity_span = t.quantity_span,
            .units = t.units,
            .units_span = t.units_span,
            .numeric = t.numeric,
            .preparation = t.preparation,
            .preparation_span = t.preparation_span,
            .is_recipe_reference = t.is_recipe_reference,
            .span = t.span,
        } });
    }

    fn appendCookware(self: *ParaState, t: Token) ParseError!void {
        try self.emitStart();
        self.closeText();
        try self.parts.append(self.a, .{ .cookware = .{
            .name = t.name,
            .name_span = t.name_span,
            .quantity = t.quantity,
            .quantity_span = t.quantity_span,
            .numeric = t.numeric,
            .span = t.span,
        } });
    }

    fn appendTimer(self: *ParaState, t: Token) ParseError!void {
        try self.emitStart();
        self.closeText();
        try self.parts.append(self.a, .{ .timer = .{
            .name = t.name,
            .name_span = t.name_span,
            .quantity = t.quantity,
            .quantity_span = t.quantity_span,
            .units = t.units,
            .units_span = t.units_span,
            .numeric = t.numeric,
            .span = t.span,
        } });
    }

    /// Finalizes the parts list, patching text values from the buffer.
    fn materialize(self: *ParaState) ParseError![]Part {
        self.closeText();
        const buf = try self.buf.toOwnedSlice(self.a);
        for (self.metas.items) |meta| {
            const value = buf[meta.buf_start..meta.buf_end];
            if (value.len == 0) continue; // defensive; never produced
            self.parts.items[meta.part_index].text.text = value;
            self.parts.items[meta.part_index].text.span = meta.span;
        }
        return self.parts.toOwnedSlice(self.a);
    }
};

/// Builds a step from a paragraph's lines, or returns null when the
/// paragraph produced no parts at all (e.g. only comments — the canonical
/// corpus expects such paragraphs to vanish).
fn buildStep(parser: *Parser, para: []const source.Span) ParseError!?Step {
    const bytes = parser.src.bytes;
    var ps = ParaState{
        .a = parser.a,
        .src = parser.src,
        .buf = std.ArrayList(u8).empty,
        .parts = std.ArrayList(Part).empty,
        .metas = std.ArrayList(TextMeta).empty,
        .diags = parser.diags,
    };
    // Precompute every `-]` in the paragraph region (byte-level; block
    // comments are opaque, so a close inside a token or later line is
    // still a close).
    var closes = std.ArrayList(u32).empty;
    {
        var search: usize = para[0].start;
        const region_end = para[para.len - 1].end;
        while (std.mem.indexOfPos(u8, bytes, search, "-]")) |f| {
            if (f >= region_end) break;
            try closes.append(parser.a, @intCast(f));
            search = f + 2;
        }
        ps.closes = try closes.toOwnedSlice(parser.a);
    }

    var li: usize = 0;
    var off: ?u32 = null;
    while (li < para.len) {
        const start: usize = off orelse para[li].start;
        off = null;
        const res = try scanLineRange(&ps, para, li, start);
        ps.join_pos = para[li].end;
        // A join fires only when the scan crossed a real line boundary
        // (a block comment closing on the same line resumes mid-line and
        // must not join).
        if (res.broke) {
            ps.pending_break = true;
            ps.break_span = res.break_span;
        } else if (res.emitted and res.next_line != li) {
            ps.pending_join = true;
        }
        li = res.next_line;
        off = res.next_offset;
    }
    // A dangling forced break at paragraph end is kept (the `\` was
    // consumed; the break renders as a trailing line break).
    if (ps.pending_break) {
        ps.closeText();
        try ps.parts.append(parser.a, .{ .line_break = ps.break_span });
    }
    const parts = try ps.materialize();
    if (parts.len == 0) return null;
    return .{
        .parts = parts,
        .span = .{ .start = @intCast(para[0].start), .end = @intCast(para[para.len - 1].end) },
    };
}

/// Scans one line's byte range `[start, line_end)` for text, tokens,
/// comments, and the forced line break. Returns where scanning resumes
/// (possibly a later line when a block comment closes there).
fn scanLineRange(ps: *ParaState, para: []const source.Span, li: usize, start: usize) ParseError!ScanRes {
    const bytes = ps.src.bytes;
    const line_end = para[li].end;
    var i: usize = start;
    var text_start: usize = i;
    var emitted = false;
    var broke = false;
    var break_span: source.Span = .{ .start = 0, .end = 0 };

    while (i < line_end) {
        if (i + 1 < line_end and bytes[i] == '-' and bytes[i + 1] == '-') {
            if (i + 2 < line_end and bytes[i + 2] == '-') {
                // A `---` run (three or more dashes) is not a comment —
                // the canonical corpus's metadata test keeps `hello ---`
                // as literal text. Skip the whole dash run so its tail
                // isn't re-read as a comment.
                while (i < line_end and bytes[i] == '-') : (i += 1) {}
                continue;
            }
            // Line comment to end of line.
            if (i > text_start) {
                try ps.appendText(text_start, i);
                emitted = true;
            }
            // Consume the rest of the line (and the trailing flush).
            i = line_end;
            text_start = i;
            break;
        }
        if (i + 1 < line_end and bytes[i] == '[' and bytes[i + 1] == '-') {
            // Block comment: closes at the next `-]` in the paragraph
            // (byte-level; the comment is opaque). Unclosed `[-` degrades
            // to literal text.
            const want = i + 2;
            while (ps.close_cursor < ps.closes.len and ps.closes[ps.close_cursor] < want) {
                ps.close_cursor += 1;
            }
            if (ps.close_cursor < ps.closes.len) {
                const close: usize = ps.closes[ps.close_cursor];
                ps.close_cursor += 1;
                if (i > text_start) {
                    try ps.appendText(text_start, i);
                    emitted = true;
                }
                // Resume after `-]`; it may be on a later line.
                var next_line = li;
                while (next_line + 1 < para.len and close + 2 >= para[next_line].end) next_line += 1;
                return .{
                    .next_line = next_line,
                    .next_offset = @intCast(close + 2),
                    .emitted = emitted,
                    .broke = false,
                };
            }
            // Unclosed: `[-` is ordinary text (the whole paragraph was
            // scanned for a `-]` above, so this is a real dangling
            // opener). The degradation is the documented behavior, but a
            // structured warning keeps it visible to consumers.
            try ps.warn("unclosed-block-comment", .{ .start = @intCast(i), .end = @intCast(i + 2) }, "unclosed block comment `[-` (no `-]` in the step)");
            i += 2;
            continue;
        }
        const b = bytes[i];
        if (b == '@' or b == '#' or b == '~') {
            if (try tryToken(ps, i, line_end)) |t| {
                if (i > text_start) {
                    try ps.appendText(text_start, i);
                    emitted = true;
                }
                switch (t.kind) {
                    .ingredient => try ps.appendIngredient(t),
                    .cookware => try ps.appendCookware(t),
                    .timer => try ps.appendTimer(t),
                }
                emitted = true;
                i = t.span.end;
                text_start = i;
                continue;
            }
            i += 1;
            continue;
        }
        if (b == '\\') {
            // Forced line break when only whitespace follows to EOL.
            var j = i + 1;
            while (j < line_end and isAsciiWs(bytes[j])) : (j += 1) {}
            if (j == line_end) {
                if (i > text_start) {
                    try ps.appendText(text_start, i);
                    emitted = true;
                }
                broke = true;
                break_span = .{ .start = @intCast(i), .end = @intCast(i + 1) };
                // Consume the `\` and trailing whitespace (and the
                // trailing flush).
                i = line_end;
                text_start = i;
                break;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    if (i > text_start) {
        try ps.appendText(text_start, i);
        emitted = true;
    }
    return .{
        .next_line = li + 1,
        .next_offset = null,
        .emitted = emitted,
        .broke = broke,
        .break_span = break_span,
    };
}

// ---------------------------------------------------------------------------
// Tokens: ingredients, cookware, timers.
// ---------------------------------------------------------------------------

const TokenKind = enum { ingredient, cookware, timer };

const Token = struct {
    kind: TokenKind,
    name: []const u8,
    name_span: source.Span,
    quantity: ?[]const u8,
    quantity_span: source.Span,
    units: ?[]const u8,
    units_span: source.Span,
    numeric: ?Quantity,
    preparation: ?[]const u8,
    preparation_span: source.Span,
    is_recipe_reference: bool,
    span: source.Span,
};

/// Attempts to parse a token starting at the marker byte `marker_pos`.
/// Returns null (the marker stays literal text) when the shape is
/// invalid. Multiword names run to the first `{` on the line; with no
/// `{`, the name is the first word (Unicode whitespace or P-category
/// punctuation ends it; symbols stay in the name, per the corpus's `@🧂`).
fn tryToken(ps: *ParaState, marker_pos: usize, line_end: usize) ParseError!?Token {
    const bytes = ps.src.bytes;
    const kind: TokenKind = switch (bytes[marker_pos]) {
        '@' => .ingredient,
        '#' => .cookware,
        '~' => .timer,
        else => unreachable,
    };
    const i = marker_pos + 1;
    // Scan the potential name region: word characters (non-P — symbols
    // like `🧂` count), spaces (part of multiword names), hyphens, and
    // the `.`/`/` of recipe-reference paths. It stops at `{` (the
    // braced/multiword form), at a token marker (`@`/`#`/`~`), or at any
    // other P-category punctuation — so `@salt, @ground black pepper{2}`
    // keeps `@salt` single-word (the `,` ends the region; this is how the
    // spec's own `@salt and @ground black pepper{}` example parses), while
    // `@ground black pepper{2}` and `@1000 island dressing{ }` reach the
    // `{` and keep the whole phrase as the name.
    var brace: ?usize = null;
    {
        var j = i;
        while (j < line_end) {
            if (unicode.decode(bytes, j)) |c| {
                if (c == '{') {
                    brace = j;
                    break;
                }
                if (c == '@' or c == '#' or c == '~') break;
                if (c == '-' or c == '.' or c == '/') {
                    j += cpLen(bytes[j]);
                    continue;
                }
                if (unicode.isPunctuationP(c)) break;
                j += cpLen(bytes[j]);
            } else {
                j += 1;
            }
        }
    }
    if (brace) |b| {
        // Multiword (or braced) form: name runs to the `{`. An unclosed
        // `{` is malformed structure: the token degrades to literal text
        // (documented behavior) with a structured warning.
        const close = findScalar(bytes, b + 1, line_end, '}') orelse {
            try ps.warn("unclosed-braces", .{ .start = @intCast(b), .end = @intCast(b + 1) }, "unclosed `{` (no `}` on the line)");
            return null;
        };
        const name_tr = trimRegion(bytes, i, b);
        if (name_tr.s == name_tr.e) {
            // An empty braced name is the unnamed timer form
            // `~{25%minutes}` — but only when the `{` is immediately after
            // the marker (`~ {5}` is invalid, per the corpus).
            if (kind != .timer or i != b) return null;
        } else {
            // The name must start with a word character — except a `.` or
            // `/`, which start recipe-reference paths (`@./sauces/...`).
            const first = unicode.decode(bytes, i);
            const path_start = first != null and (first.? == '.' or first.? == '/');
            if (first == null or unicode.isWhitespace(first.?) or (unicode.isPunctuationP(first.?) and !path_start)) return null;
        }
        const name = bytes[name_tr.s..name_tr.e];

        const content_start = b + 1;
        const pct = findScalar(bytes, content_start, close, '%');
        const qr = if (pct) |p| trimRegion(bytes, content_start, p) else trimRegion(bytes, content_start, close);
        const ur: Trimmed = if (pct) |p| trimRegion(bytes, p + 1, close) else .{ .s = close, .e = close };
        const quantity: ?[]const u8 = if (qr.s < qr.e) bytes[qr.s..qr.e] else "";
        const units: ?[]const u8 = if (ur.s < ur.e) bytes[ur.s..ur.e] else "";
        const numeric: ?Quantity = if (quantity.?.len > 0) parseQuantity(quantity.?) else null;

        // Shorthand preparation: an immediate `(...)` after the `}`.
        var preparation: ?[]const u8 = null;
        var preparation_span: source.Span = .{ .start = @intCast(close + 1), .end = @intCast(close + 1) };
        var token_end = close + 1;
        if (token_end < line_end and bytes[token_end] == '(') {
            if (findScalar(bytes, token_end + 1, line_end, ')')) |pc| {
                const pr = trimRegion(bytes, token_end + 1, pc);
                preparation = bytes[pr.s..pr.e];
                preparation_span = .{ .start = @intCast(token_end), .end = @intCast(pc + 1) };
                token_end = pc + 1;
            } else {
                // A `(` right after the closing brace with no `)` on the
                // line: an unclosed shorthand preparation. The `(` stays
                // literal text; a structured warning keeps it visible.
                try ps.warn("unclosed-preparation", .{ .start = @intCast(token_end), .end = @intCast(token_end + 1) }, "unclosed preparation `(` (no `)` on the line)");
            }
        }

        return .{
            .kind = kind,
            .name = name,
            .name_span = .{ .start = @intCast(name_tr.s), .end = @intCast(name_tr.e) },
            .quantity = quantity,
            .quantity_span = .{ .start = @intCast(qr.s), .end = @intCast(qr.e) },
            .units = units,
            .units_span = .{ .start = @intCast(ur.s), .end = @intCast(ur.e) },
            .numeric = numeric,
            .preparation = preparation,
            .preparation_span = preparation_span,
            .is_recipe_reference = isRecipeReference(name),
            .span = .{ .start = @intCast(marker_pos), .end = @intCast(token_end) },
        };
    }
    // Single-word form: no `{` on the line. The word runs while the
    // code point is neither whitespace nor P-category punctuation.
    const word_start = i;
    var k = i;
    while (k < line_end) {
        if (unicode.decode(bytes, k)) |cp| {
            if (unicode.isWhitespace(cp) or unicode.isPunctuationP(cp)) break;
            k += cpLen(bytes[k]);
        } else {
            // Malformed UTF-8: not whitespace, not punctuation.
            k += 1;
        }
    }
    if (k == word_start) return null;
    const name = bytes[word_start..k];
    return .{
        .kind = kind,
        .name = name,
        .name_span = .{ .start = @intCast(word_start), .end = @intCast(k) },
        .quantity = null,
        .quantity_span = .{ .start = @intCast(k), .end = @intCast(k) },
        .units = null,
        .units_span = .{ .start = @intCast(k), .end = @intCast(k) },
        .numeric = null,
        .preparation = null,
        .preparation_span = .{ .start = @intCast(k), .end = @intCast(k) },
        .is_recipe_reference = false,
        .span = .{ .start = @intCast(marker_pos), .end = @intCast(k) },
    };
}

/// True for names that reference another recipe (`@./sauces/Hollandaise`).
/// Oliver never resolves the path; resolution is a consumer concern.
fn isRecipeReference(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "./") or
        std.mem.startsWith(u8, name, "../") or
        std.mem.startsWith(u8, name, "/");
}

fn cpLen(b0: u8) usize {
    if (b0 < 0x80) return 1;
    if (b0 >= 0xC2 and b0 <= 0xDF) return 2;
    if (b0 >= 0xE0 and b0 <= 0xEF) return 3;
    if (b0 >= 0xF0 and b0 <= 0xF4) return 4;
    return 1;
}

fn findScalar(bytes: []const u8, from: usize, to: usize, c: u8) ?usize {
    var i = from;
    while (i < to) : (i += 1) {
        if (bytes[i] == c) return i;
    }
    return null;
}

/// Classification of an amount string for scaling (docs/COOKLANG.md §11).
/// Closed, after trimming ASCII space/tab: `empty` is `""`; `scalable`
/// is a canonical unsigned integer, `a/b` (`b ≠ 0`; spaces around `/`
/// allowed), decimal `a.b`, or mixed `a b/c`; everything else —
/// including a leading `=`, ranges (`1-2`), words (`some`), and `1/0`
/// — is `fixed`. This is the exact-rational grammar, not
/// `parseQuantity`'s f64 decimal arm.
pub const QuantityClass = enum { empty, scalable, fixed };

/// Classifies an authored quantity string. Leading and trailing ASCII
/// space/tab are ignored. A leading `=` is `fixed` even when the rest
/// would parse (`=1`, `=1/2`).
pub fn classifyQuantity(amount: []const u8) QuantityClass {
    const text = std.mem.trim(u8, amount, " \t");
    if (text.len == 0) return .empty;
    if (text[0] == '=') return .fixed;
    if (isScalableQuantity(text)) return .scalable;
    return .fixed;
}

/// The parts of a mixed number `a b/c` (whole + proper fraction).
/// `den ≠ 0` and `num < den`; the separator is one or more ASCII
/// space/tab (the same trim set used elsewhere). Spaces around the
/// slash are allowed, matching `parseQuantity`'s fraction arm.
pub const MixedNumber = struct {
    whole: u64,
    num: u64,
    den: u64,
};

/// Parses a mixed number. Null when `text` is not `whole` + space/tab
/// + a proper fraction of two canonical integers. Shared by
/// `parseQuantity`, `classifyQuantity`, and the exact scale path.
pub fn parseMixedNumber(text: []const u8) ?MixedNumber {
    const parts = splitMixed(text) orelse return null;
    const whole = parseCanonicalU64(parts.whole) orelse return null;
    const num = parseCanonicalU64(parts.num) orelse return null;
    const den = parseCanonicalU64(parts.den) orelse return null;
    if (den == 0 or num >= den) return null;
    return .{ .whole = whole, .num = num, .den = den };
}

const MixedParts = struct {
    whole: []const u8,
    num: []const u8,
    den: []const u8,
};

/// Splits `whole<space/tab>+num[/]den` without validating the numbers.
fn splitMixed(text: []const u8) ?MixedParts {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ' ' and text[i] != '\t') continue;
        const rest = std.mem.trim(u8, text[i + 1 ..], " \t");
        const slash = findScalar(rest, 0, rest.len, '/') orelse return null;
        return .{
            .whole = text[0..i],
            .num = std.mem.trim(u8, rest[0..slash], " \t"),
            .den = std.mem.trim(u8, rest[slash + 1 ..], " \t"),
        };
    }
    return null;
}

fn isScalableQuantity(text: []const u8) bool {
    if (parseCanonicalU64(text) != null) return true;
    if (isCanonicalDecimal(text)) return true;
    if (isCanonicalFraction(text)) return true;
    if (parseMixedNumber(text) != null) return true;
    return false;
}

fn isCanonicalDecimal(text: []const u8) bool {
    const d = findScalar(text, 0, text.len, '.') orelse return false;
    if (findScalar(text, d + 1, text.len, '.') != null) return false;
    return parseCanonicalU64(text[0..d]) != null and isDigits(text[d + 1 ..]);
}

fn isCanonicalFraction(text: []const u8) bool {
    const s = findScalar(text, 0, text.len, '/') orelse return false;
    if (findScalar(text, s + 1, text.len, '/') != null) return false;
    _ = parseCanonicalU64(std.mem.trim(u8, text[0..s], " \t")) orelse return false;
    const den = parseCanonicalU64(std.mem.trim(u8, text[s + 1 ..], " \t")) orelse return false;
    return den != 0;
}

/// `"0"` or `[1-9][0-9]*` as u64, when it fits. Leading zeros other
/// than a lone `0` are rejected (the same canonical-integer rule as
/// `parseQuantity`).
fn parseCanonicalU64(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    if (text[0] == '0') return if (text.len == 1) 0 else null;
    if (!isDigits(text)) return null;
    return std.fmt.parseUnsigned(u64, text, 10) catch null;
}

/// The numeric view of a quantity: only canonical forms — an integer
/// (`0` or no leading zero), a decimal, a fraction of two canonical
/// integers with a non-zero denominator (so `01/2` stays text, per the
/// corpus), or a mixed number `1 1/2` (whole + proper fraction).
/// Everything else stays a string; the source text is always
/// preserved by the model. Public so derived operations (scaling,
/// conformance comparisons) share one acceptance rule. The decimal
/// arm still uses f64; scaling must go through the exact path in
/// `cooklang_scale` instead.
pub fn parseQuantity(text: []const u8) ?Quantity {
    if (canonicalInt(text)) |v| return .{ .int = v };
    if (findScalar(text, 0, text.len, '.')) |d| {
        const ip = text[0..d];
        const fp = text[d + 1 ..];
        if (canonicalInt(ip) != null and isDigits(fp)) {
            return .{ .decimal = std.fmt.parseFloat(f64, text) catch return null };
        }
        return null;
    }
    // Mixed before the simple-fraction arm: `1 1/2` contains `/`, and
    // the left-hand side `1 1` is not a canonical integer.
    if (parseMixedNumber(text)) |m| {
        const whole_part = std.math.mul(u64, m.whole, m.den) catch return null;
        const combined = std.math.add(u64, whole_part, m.num) catch return null;
        if (combined > std.math.maxInt(u32) or m.den > std.math.maxInt(u32)) return null;
        return .{ .fraction = .{ .num = @intCast(combined), .den = @intCast(m.den) } };
    }
    if (findScalar(text, 0, text.len, '/')) |s| {
        // Spaces around the slash are allowed (`1 / 2` -> `1/2`, per the
        // corpus); the parts are trimmed individually.
        const num = canonicalInt(std.mem.trim(u8, text[0..s], " \t")) orelse return null;
        const den = canonicalInt(std.mem.trim(u8, text[s + 1 ..], " \t")) orelse return null;
        if (den == 0) return null;
        if (num > std.math.maxInt(u32) or den > std.math.maxInt(u32)) return null;
        return .{ .fraction = .{ .num = @intCast(num), .den = @intCast(den) } };
    }
    return null;
}

/// `"0"` or `[1-9][0-9]*`; null otherwise.
fn canonicalInt(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    if (text[0] == '0') return if (text.len == 1) 0 else null;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

fn parseT(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
    return parse(allocator, input, .{});
}

fn expectParts(parts: []const Part, comptime names: []const []const u8) !void {
    // `names` holds the expected token names (empty strings for text
    // parts, which are skipped); the remaining parts must match in order.
    var ti: usize = 0;
    for (parts) |p| {
        switch (p) {
            .ingredient => |ig| {
                try std.testing.expect(ti < names.len);
                try std.testing.expectEqualStrings(names[ti], ig.name);
                ti += 1;
            },
            .cookware => |cw| {
                try std.testing.expect(ti < names.len);
                try std.testing.expectEqualStrings(names[ti], cw.name);
                ti += 1;
            },
            .timer => |tm| {
                try std.testing.expect(ti < names.len);
                try std.testing.expectEqualStrings(names[ti], tm.name);
                ti += 1;
            },
            .line_break => {},
            .text => {},
        }
    }
    try std.testing.expectEqual(names.len, ti);
}

test "cooklang: basic ingredient with surrounding text" {
    var res = try parseT(std.testing.allocator, "Add @salt");
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.recipe.blocks.len);
    const step = res.recipe.blocks[0].step;
    try std.testing.expectEqual(@as(usize, 2), step.parts.len);
    try std.testing.expectEqualStrings("Add ", step.parts[0].text.text);
    const ig = step.parts[1].ingredient;
    try std.testing.expectEqualStrings("salt", ig.name);
    try std.testing.expect(ig.quantity == null);
    try std.testing.expectEqual(@as(u32, 4), ig.span.start);
    try std.testing.expectEqual(@as(u32, 9), ig.span.end);
}

test "cooklang: multiword ingredient with quantity and units" {
    var res = try parseT(std.testing.allocator, "Add @hot chilli{3} and @ground black pepper{}");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try expectParts(step.parts, &.{ "hot chilli", "ground black pepper" });
    const ig1 = step.parts[1].ingredient;
    try std.testing.expectEqualStrings("3", ig1.quantity.?);
    try std.testing.expect(ig1.units.?.len == 0);
    try std.testing.expectEqual(Quantity{ .int = 3 }, ig1.numeric.?);
    const ig2 = step.parts[3].ingredient;
    try std.testing.expectEqualStrings("ground black pepper", ig2.name);
    try std.testing.expect(ig2.quantity.?.len == 0);
}

test "cooklang: quantity units, trimming, and numeric forms" {
    var res = try parseT(std.testing.allocator, "@milk{1/2%cup} @water{ 3 % items } @syrup{01/2%tbsp}");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    const ig1 = step.parts[0].ingredient;
    try std.testing.expectEqualStrings("1/2", ig1.quantity.?);
    try std.testing.expectEqualStrings("cup", ig1.units.?);
    try std.testing.expectEqual(Quantity{ .fraction = .{ .num = 1, .den = 2 } }, ig1.numeric.?);
    const ig2 = step.parts[2].ingredient;
    try std.testing.expectEqualStrings("3", ig2.quantity.?);
    try std.testing.expectEqualStrings("items", ig2.units.?);
    const ig3 = step.parts[4].ingredient;
    try std.testing.expectEqualStrings("01/2", ig3.quantity.?);
    try std.testing.expect(ig3.numeric == null);
}

test "cooklang: decimal and fractional timers, named and unnamed" {
    var res = try parseT(std.testing.allocator, "Fry for ~{1.5%minutes} then ~eggs{3%minutes} and ~rest");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    const t1 = step.parts[1].timer;
    try std.testing.expectEqualStrings("", t1.name);
    try std.testing.expectEqualStrings("1.5", t1.quantity.?);
    try std.testing.expectEqualStrings("minutes", t1.units.?);
    try std.testing.expectEqual(Quantity{ .decimal = 1.5 }, t1.numeric.?);
    const t2 = step.parts[3].timer;
    try std.testing.expectEqualStrings("eggs", t2.name);
    try std.testing.expectEqual(Quantity{ .int = 3 }, t2.numeric.?);
    const t3 = step.parts[5].timer;
    try std.testing.expectEqualStrings("rest", t3.name);
    try std.testing.expect(t3.quantity == null); // no braces: no explicit quantity
}

test "cooklang: cookware single and multiword" {
    // A braced token later on the line does not swallow an earlier
    // single-word token: the multiword name region stops at punctuation.
    var res = try parseT(std.testing.allocator, "Simmer in #pot and #frying pan{2}");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try expectParts(step.parts, &.{ "pot", "frying pan" });
    const cw = step.parts[3].cookware;
    try std.testing.expectEqualStrings("2", cw.quantity.?);
    try std.testing.expectEqual(Quantity{ .int = 2 }, cw.numeric.?);
}

test "cooklang: emoji stays in the name; punctuation and whitespace end it" {
    var res = try parseT(std.testing.allocator, "Add @🧂 and @chilli, then @pot\u{2009}ok");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try expectParts(step.parts, &.{ "🧂", "chilli", "pot" });
    const last = step.parts[step.parts.len - 1].text;
    try std.testing.expectEqualStrings("\u{2009}ok", last.text);
}

test "cooklang: invalid token shapes stay literal" {
    var res = try parseT(std.testing.allocator, "Message @ example{} and @{3} and ~ 5 and # 10{}");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try std.testing.expectEqual(@as(usize, 1), step.parts.len);
    try std.testing.expectEqualStrings("Message @ example{} and @{3} and ~ 5 and # 10{}", step.parts[0].text.text);
}

test "cooklang: shorthand preparation attaches to the ingredient" {
    var res = try parseT(std.testing.allocator, "Mix @onion{1}(peeled and finely chopped).");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    const ig = step.parts[1].ingredient;
    try std.testing.expectEqualStrings("peeled and finely chopped", ig.preparation.?);
    try std.testing.expectEqual(@as(u32, 13), ig.preparation_span.start);
    try std.testing.expectEqual(@as(u32, 40), ig.preparation_span.end);
    // A spaced paren is not a preparation.
    var res2 = try parseT(std.testing.allocator, "@onion{1} (not prep)");
    defer res2.deinit();
    const ig2 = res2.recipe.blocks[0].step.parts[0].ingredient;
    try std.testing.expect(ig2.preparation == null);
}

test "cooklang: recipe references are marked, never resolved" {
    var res = try parseT(std.testing.allocator, "Pour over with @./sauces/Hollandaise{150%g}.");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    const ig = step.parts[1].ingredient;
    try std.testing.expectEqualStrings("./sauces/Hollandaise", ig.name);
    try std.testing.expect(ig.is_recipe_reference);
    try std.testing.expectEqualStrings("150", ig.quantity.?);
    // A plain ingredient is not a reference.
    var res2 = try parseT(std.testing.allocator, "@sauces{1}");
    defer res2.deinit();
    try std.testing.expect(!res2.recipe.blocks[0].step.parts[0].ingredient.is_recipe_reference);
}

test "cooklang: the spec's own multiword example parses as two ingredients" {
    // "Add @salt and @ground black pepper{}" (the spec page) must yield
    // `@salt` single-word and `@ground black pepper` multiword: the name
    // region stops at a following token marker and at P-category
    // punctuation, so a later `{` never swallows an earlier token.
    var res = try parseT(std.testing.allocator, "Add @salt and @ground black pepper{}.");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try expectParts(step.parts, &.{ "salt", "ground black pepper" });

    // Same rule with quantities: `@salt and @pepper{1%tsp}` is two
    // ingredients, not one long name.
    var res2 = try parseT(std.testing.allocator, "Add @salt and @pepper{1%tsp}.");
    defer res2.deinit();
    const step2 = res2.recipe.blocks[0].step;
    try expectParts(step2.parts, &.{ "salt", "pepper" });
    const ig = step2.parts[3].ingredient;
    try std.testing.expectEqualStrings("pepper", ig.name);
    try std.testing.expectEqualStrings("1", ig.quantity.?);
}

test "cooklang: line and block comments are removed" {
    var res = try parseT(std.testing.allocator, "Mash @potato{2%kg} -- alternatively, boil 'em\nuntil smooth");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try std.testing.expectEqual(@as(usize, 3), step.parts.len);
    const ig = step.parts[1].ingredient;
    try std.testing.expectEqualStrings("potato", ig.name);
    // Line-1 trailing space + join space + continuation text (canonical).
    try std.testing.expectEqualStrings("  until smooth", step.parts[2].text.text);

    var res2 = try parseT(std.testing.allocator, "Slowly add @milk{4%cup} [- TODO change units -], keep mixing");
    defer res2.deinit();
    const step2 = res2.recipe.blocks[0].step;
    try std.testing.expectEqual(@as(usize, 3), step2.parts.len);
    try std.testing.expectEqualStrings("Slowly add ", step2.parts[0].text.text);
    // The source space before `[-` is retained (canonical line-comment
    // behavior), merging with the text after the comment.
    try std.testing.expectEqualStrings(" , keep mixing", step2.parts[2].text.text);

    // Only comments: the paragraph vanishes.
    var res3 = try parseT(std.testing.allocator, "-- testing comments");
    defer res3.deinit();
    try std.testing.expectEqual(@as(usize, 0), res3.recipe.blocks.len);
}

test "cooklang: block comments span lines; unclosed degrades to literal" {
    var res = try parseT(std.testing.allocator, "text [- comment\nspanning -] more");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try std.testing.expectEqual(@as(usize, 1), step.parts.len);
    try std.testing.expectEqualStrings("text   more", step.parts[0].text.text);

    var res2 = try parseT(std.testing.allocator, "abc [- never closed");
    defer res2.deinit();
    const step2 = res2.recipe.blocks[0].step;
    try std.testing.expectEqualStrings("abc [- never closed", step2.parts[0].text.text);
}

test "cooklang: forced line breaks" {
    var res = try parseT(std.testing.allocator, "Lay out the @rice paper{1}.\\\nTop with @avocado{1/2}(sliced).");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try expectParts(step.parts, &.{ "rice paper", "avocado" });
    var found_break = false;
    for (step.parts) |p| {
        if (p == .line_break) found_break = true;
    }
    try std.testing.expect(found_break);
    const ig = step.parts[5].ingredient;
    try std.testing.expectEqualStrings("avocado", ig.name);
    try std.testing.expectEqualStrings("sliced", ig.preparation.?);
    // Mid-line backslash is literal.
    var res2 = try parseT(std.testing.allocator, "a \\ b");
    defer res2.deinit();
    try std.testing.expectEqualStrings("a \\ b", res2.recipe.blocks[0].step.parts[0].text.text);
}

test "cooklang: steps are blank-line separated" {
    var res = try parseT(std.testing.allocator, "Add a bit of chilli\n\nAdd a bit of hummus");
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.recipe.blocks.len);
    try std.testing.expectEqualStrings("Add a bit of chilli", res.recipe.blocks[0].step.parts[0].text.text);
    try std.testing.expectEqualStrings("Add a bit of hummus", res.recipe.blocks[1].step.parts[0].text.text);
}

test "cooklang: notes strip the marker and are never token-scanned" {
    var res = try parseT(std.testing.allocator, "> Don't burn the @roux!\n> Even better the next day");
    defer res.deinit();
    const note = res.recipe.blocks[0].note;
    try std.testing.expectEqualStrings("Don't burn the @roux! Even better the next day", note.text);
    try std.testing.expectEqual(@as(usize, 1), res.recipe.blocks.len);
}

test "cooklang: sections group blocks until the next header" {
    var res = try parseT(std.testing.allocator, "= Dough\n\nMix @flour{200%g}.\n\n== Filling ==\nCombine @cheese{100%g}.\n\nAdd @milk{1%cup}.");
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.recipe.blocks.len);
    const sec1 = res.recipe.blocks[0].section;
    try std.testing.expectEqualStrings("Dough", sec1.name);
    try std.testing.expectEqual(@as(usize, 1), sec1.blocks.len);
    const sec2 = res.recipe.blocks[1].section;
    try std.testing.expectEqualStrings("Filling", sec2.name);
    try std.testing.expectEqual(@as(usize, 2), sec2.blocks.len);
}

test "cooklang: section marker variants" {
    var res = try parseT(std.testing.allocator, "==Dough==\nStep.\n\n=\nEmpty name section.");
    defer res.deinit();
    try std.testing.expectEqualStrings("Dough", res.recipe.blocks[0].section.name);
    try std.testing.expectEqualStrings("", res.recipe.blocks[1].section.name);
    // The section title is never token-scanned.
    var res2 = try parseT(std.testing.allocator, "= @notan{1} ingredient\nStep.");
    defer res2.deinit();
    try std.testing.expectEqualStrings("@notan{1} ingredient", res2.recipe.blocks[0].section.name);
}

test "cooklang: YAML front matter boundaries only" {
    var res = try parseT(std.testing.allocator, "---\nsourced: babooshka\n---\n\nAdd @salt.");
    defer res.deinit();
    const fm = res.recipe.frontmatter.?;
    try std.testing.expectEqualStrings("sourced: babooshka\n", fm.raw);
    try std.testing.expectEqual(@as(u32, 0), fm.span.start);
    try std.testing.expectEqual(@as(u32, 27), fm.span.end);
    try std.testing.expectEqual(@as(usize, 1), res.recipe.blocks.len);

    // A `---` that is not the first line is ordinary text.
    var res2 = try parseT(std.testing.allocator, "hello ---\nsourced: babooshka\n---");
    defer res2.deinit();
    try std.testing.expect(res2.recipe.frontmatter == null);
    try std.testing.expectEqualStrings("hello --- sourced: babooshka ---", res2.recipe.blocks[0].step.parts[0].text.text);

    // An unclosed fence is ordinary text.
    var res3 = try parseT(std.testing.allocator, "---\ntitle: x");
    defer res3.deinit();
    try std.testing.expect(res3.recipe.frontmatter == null);
}

test "cooklang: frontmatter option parses metadata beside raw" {
    // docs/FRONTMATTER.md §8: with `ParseOptions.frontmatter` on, the
    // Recipe exposes the parsed view beside the unchanged raw/span
    // boundary contract.
    var res = try parse(std.testing.allocator, "---\nsourced: babooshka\n---\n\nAdd @salt.", .{ .frontmatter = .yaml });
    defer res.deinit();
    const fm = res.recipe.frontmatter.?;
    try std.testing.expectEqualStrings("sourced: babooshka\n", fm.raw);
    try std.testing.expectEqual(@as(u32, 0), fm.span.start);
    const m = res.recipe.metadata.?;
    try std.testing.expectEqual(@as(usize, 1), m.entries.len);
    try std.testing.expectEqualStrings("sourced", m.entries[0].key);
    try std.testing.expectEqualStrings("babooshka", m.entries[0].value.scalar);
    try std.testing.expectEqual(@as(usize, 1), res.recipe.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
}

test "cooklang: default options keep the parsed view null" {
    // Boundary behavior unchanged until the option is on: the raw
    // frontmatter is recognized, never parsed.
    var res = try parseT(std.testing.allocator, "---\nsourced: babooshka\n---\n\nAdd @salt.");
    defer res.deinit();
    try std.testing.expect(res.recipe.frontmatter != null);
    try std.testing.expect(res.recipe.metadata == null);
}

test "cooklang: toml fence with the toml option" {
    var res = try parse(std.testing.allocator, "+++\ntitle = \"Hello\"\n+++\nAdd @salt.", .{ .frontmatter = .toml });
    defer res.deinit();
    try std.testing.expect(res.recipe.frontmatter != null);
    const m = res.recipe.metadata.?;
    try std.testing.expectEqualStrings("Hello", m.entries[0].value.scalar);
}

test "cooklang: empty input and CRLF" {
    var res = try parseT(std.testing.allocator, "");
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.recipe.blocks.len);
    try std.testing.expect(res.recipe.frontmatter == null);

    var res2 = try parseT(std.testing.allocator, "Add @salt\r\n\r\nAdd @pepper\r\n");
    defer res2.deinit();
    try std.testing.expectEqual(@as(usize, 2), res2.recipe.blocks.len);
    try std.testing.expectEqualStrings("salt", res2.recipe.blocks[0].step.parts[1].ingredient.name);
}

test "cooklang: unicode names and malformed utf8 degrade safely" {
    var res = try parseT(std.testing.allocator, "Add @olive oil{1%l} and @garlic");
    defer res.deinit();
    const step = res.recipe.blocks[0].step;
    try expectParts(step.parts, &.{ "olive oil", "garlic" });

    // A malformed byte is treated as a word character (not whitespace,
    // not punctuation), so the token still parses deterministically.
    var res2 = try parseT(std.testing.allocator, "@abc\xFFdef{1}");
    defer res2.deinit();
    const ig = res2.recipe.blocks[0].step.parts[0].ingredient;
    try std.testing.expectEqualStrings("abc\xFFdef", ig.name);
}

test "cooklang: bounded behavior on hostile input" {
    // Huge runs of markers and braces stay linear: everything degrades
    // to literal text without pathological rescanning.
    var big = std.ArrayList(u8).empty;
    defer big.deinit(std.testing.allocator);
    for (0..2000) |_| try big.appendSlice(std.testing.allocator, "@@@{{{}}} ");
    var res = try parseT(std.testing.allocator, big.items);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.recipe.blocks.len);
    // The trailing space is part of the line's text.
    try std.testing.expectEqualStrings(big.items, res.recipe.blocks[0].step.parts[0].text.text);

    // Unterminated block comments everywhere: still one pass, literal.
    var big2 = std.ArrayList(u8).empty;
    defer big2.deinit(std.testing.allocator);
    for (0..1000) |_| try big2.appendSlice(std.testing.allocator, "[- x ");
    var res2 = try parseT(std.testing.allocator, big2.items);
    defer res2.deinit();
    try std.testing.expectEqualStrings(big2.items, res2.recipe.blocks[0].step.parts[0].text.text);

    // Many steps.
    var big3 = std.ArrayList(u8).empty;
    defer big3.deinit(std.testing.allocator);
    for (0..1000) |_| try big3.appendSlice(std.testing.allocator, "@salt\n\n");
    var res3 = try parseT(std.testing.allocator, big3.items);
    defer res3.deinit();
    try std.testing.expectEqual(@as(usize, 1000), res3.recipe.blocks.len);
}

test "cooklang: structured diagnostics for malformed structure" {
    // Unclosed `{`: the token degrades to literal text (no part), and a
    // warning carries the `{` position.
    var res = try parseT(std.testing.allocator, "Mix @flour{200");
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.diagnostics.len);
    const d = res.diagnostics[0];
    try std.testing.expectEqual(diagnostic.Severity.warning, d.severity);
    try std.testing.expectEqualStrings("unclosed-braces", d.code);
    try std.testing.expectEqual(@as(u32, 10), d.span.start);
    try std.testing.expectEqual(@as(u32, 11), d.span.end);
    try std.testing.expectEqual(@as(u32, 11), d.offset);
    try std.testing.expectEqual(@as(u32, 1), d.line);
    try std.testing.expectEqual(@as(u32, 11), d.column);

    // Unclosed preparation `(`.
    var res2 = try parseT(std.testing.allocator, "Add @x{1}(sliced");
    defer res2.deinit();
    try std.testing.expectEqual(@as(usize, 1), res2.diagnostics.len);
    try std.testing.expectEqualStrings("unclosed-preparation", res2.diagnostics[0].code);
    // The ingredient still parses and the `(` stays literal text.
    try std.testing.expectEqual(@as(usize, 3), res2.recipe.blocks[0].step.parts.len);

    // Unclosed block comment `[-` (across the whole paragraph).
    var res3 = try parseT(std.testing.allocator, "Note with [- unclosed");
    defer res3.deinit();
    try std.testing.expectEqual(@as(usize, 1), res3.diagnostics.len);
    try std.testing.expectEqualStrings("unclosed-block-comment", res3.diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 10), res3.diagnostics[0].span.start);

    // A closed `[- -]` comment warns nothing.
    var res4 = try parseT(std.testing.allocator, "Note [- closed -] fine");
    defer res4.deinit();
    try std.testing.expectEqual(@as(usize, 0), res4.diagnostics.len);

    // A dangling front matter fence warns; the content stays ordinary
    // text (the `---` opener is not consumed).
    var res5 = try parseT(std.testing.allocator, "---\ntitle: x\n");
    defer res5.deinit();
    try std.testing.expectEqual(@as(usize, 1), res5.diagnostics.len);
    try std.testing.expectEqualStrings("unclosed-frontmatter", res5.diagnostics[0].code);
    try std.testing.expect(res5.recipe.frontmatter == null);

    // Corpus-pinned near-misses stay silent: no diagnostics.
    var res6 = try parseT(std.testing.allocator, "Message @ example{} and ~ {5} and ~ 5");
    defer res6.deinit();
    try std.testing.expectEqual(@as(usize, 0), res6.diagnostics.len);
}

test "cooklang: classifyQuantity closed forms" {
    try std.testing.expectEqual(QuantityClass.empty, classifyQuantity(""));
    try std.testing.expectEqual(QuantityClass.empty, classifyQuantity("   "));
    try std.testing.expectEqual(QuantityClass.empty, classifyQuantity("\t"));
    try std.testing.expectEqual(QuantityClass.scalable, classifyQuantity("2"));
    try std.testing.expectEqual(QuantityClass.scalable, classifyQuantity("1/2"));
    try std.testing.expectEqual(QuantityClass.scalable, classifyQuantity("1 / 2"));
    try std.testing.expectEqual(QuantityClass.scalable, classifyQuantity("1.5"));
    try std.testing.expectEqual(QuantityClass.scalable, classifyQuantity("1 1/2"));
    try std.testing.expectEqual(QuantityClass.scalable, classifyQuantity("  1 1/2  "));
    try std.testing.expectEqual(QuantityClass.fixed, classifyQuantity("=1"));
    try std.testing.expectEqual(QuantityClass.fixed, classifyQuantity("=1/2"));
    try std.testing.expectEqual(QuantityClass.fixed, classifyQuantity("1-2"));
    try std.testing.expectEqual(QuantityClass.fixed, classifyQuantity("some"));
    try std.testing.expectEqual(QuantityClass.fixed, classifyQuantity("1/0"));
    try std.testing.expectEqual(QuantityClass.fixed, classifyQuantity("02"));
    try std.testing.expectEqual(QuantityClass.fixed, classifyQuantity("1 3/2"));
}

test "cooklang: parseQuantity accepts mixed numbers" {
    try std.testing.expectEqual(Quantity{ .fraction = .{ .num = 3, .den = 2 } }, parseQuantity("1 1/2").?);
    try std.testing.expectEqual(Quantity{ .fraction = .{ .num = 5, .den = 2 } }, parseQuantity("2 1/2").?);
    try std.testing.expectEqual(Quantity{ .fraction = .{ .num = 5, .den = 4 } }, parseQuantity("1 1 / 4").?);
    try std.testing.expectEqual(Quantity{ .fraction = .{ .num = 3, .den = 2 } }, parseQuantity("1\t1/2").?);
    try std.testing.expect(parseQuantity("1 3/2") == null);
    try std.testing.expect(parseQuantity("1 1/0") == null);
    try std.testing.expect(parseQuantity("01 1/2") == null);
    var res = try parseT(std.testing.allocator, "@flour{1 1/2%cup}");
    defer res.deinit();
    const ig = res.recipe.blocks[0].step.parts[0].ingredient;
    try std.testing.expectEqualStrings("1 1/2", ig.quantity.?);
    try std.testing.expectEqual(Quantity{ .fraction = .{ .num = 3, .den = 2 } }, ig.numeric.?);
}
