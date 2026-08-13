//! Bounded Cooklang-to-Markdown body adapter with structured recipe extraction.
//!
//! Normative: `docs/contracts/cooklang-compatibility.md`.
//! This module is pure: no filesystem, renderer, layout, graph, or process access.
//!
//! Cooklang metadata is YAML front matter, which is already Boris frontmatter,
//! so this adapter never sees it: `parser.zig` splits frontmatter off first and
//! this module adapts only the body, exactly as `textile.zig` does.
//!
//! Two outputs from one pass:
//!
//! 1. **Markdown** for the ordinary compile path — the adapted body enters the
//!    same component/parser pipeline as any Markdown page, rendered through
//!    Oliver.
//! 2. **A `Recipe`** — the ingredients, cookware and timers as structured data,
//!    which is the whole reason a recipe format is worth supporting. It reaches
//!    the IR and the RAG corpus, where prose alone would be unqueryable.
//!
//! Author text is escaped on the way out. Recipe prose is untrusted input, and
//! an unescaped `#` or `- ` would let a step forge a heading or a list item in
//! the document that contains it.

const std = @import("std");
const identity = @import("identity.zig");

pub const adapter_identity = "boris-cooklang-adapter-v1";

/// Bounds on one recipe, mirroring `page.max_relation_count` for the IR 0.3
/// facet. The 0.4 facet is the first thing to copy author text verbatim into
/// `graph.json`, so an unbounded one is an amplifier: a 1 MiB `.cook` file of
/// `@a{1}` repeats is ~210k ingredients and tens of MB of IR from one page.
/// `max_source_bytes` caps the input, but the facet should carry its own limit
/// for the same reason the relations facet does.
pub const max_ingredient_count: usize = 512;
pub const max_cookware_count: usize = 128;
pub const max_timer_count: usize = 128;
/// Longest accepted ingredient, cookware, or timer name, in bytes.
pub const max_token_name_bytes: usize = 256;

pub const Diagnostic = struct {
    /// 1-based body-relative line.
    line: u32 = 1,
    /// 1-based byte column within the original Cooklang line.
    column: u32 = 1,
    message: []const u8,
};

/// A quantity exactly as authored. Deliberately text, not a number: Cooklang
/// admits `2`, `1/2`, `1.5`, `1-2` and bare words like `some`, and inventing a
/// numeric model here would either reject valid recipes or silently round them.
/// Scaling and shopping-list arithmetic need that model and are not in v1.
pub const Quantity = struct {
    /// Amount text before any `%`. Empty when the author gave none.
    amount: []const u8 = "",
    /// Unit text after `%`. Empty when the author gave none.
    unit: []const u8 = "",

    pub fn isEmpty(self: Quantity) bool {
        return self.amount.len == 0 and self.unit.len == 0;
    }
};

pub const Ingredient = struct {
    /// Display name. For a recipe reference this is the final path segment.
    name: []const u8,
    quantity: Quantity = .{},
    /// Short-hand preparation from a trailing `(...)`. Empty when absent.
    preparation: []const u8 = "",
    /// Entity id when the author wrote a recipe reference (`@./sauces/Hollandaise`),
    /// normalized to a content-root-relative id with no `./` prefix and no
    /// extension. Empty for an ordinary ingredient.
    recipe_ref: []const u8 = "",

    pub fn isRecipeRef(self: Ingredient) bool {
        return self.recipe_ref.len > 0;
    }
};

pub const Cookware = struct {
    name: []const u8,
    quantity: Quantity = .{},
};

pub const Timer = struct {
    /// Optional timer name (`~eggs{3%minutes}`). Empty for an anonymous timer.
    name: []const u8 = "",
    quantity: Quantity = .{},
};

/// Structured recipe data extracted from one `.cook` body.
///
/// Every slice preserves authored order and holds one entry per reference. No
/// aggregation: merging two `@flour` references means adding `200%g` to `1%cup`,
/// which is not decidable without a unit model. A consumer that wants a merged
/// shopping list can group these; a consumer that wants fidelity has it.
pub const Recipe = struct {
    ingredients: []const Ingredient = &.{},
    cookware: []const Cookware = &.{},
    timers: []const Timer = &.{},

    pub fn isEmpty(self: Recipe) bool {
        return self.ingredients.len == 0 and self.cookware.len == 0 and self.timers.len == 0;
    }
};

pub const Result = struct {
    /// Allocator-owned on success. Empty when `diagnostic` is set.
    markdown: []const u8 = "",
    /// Structured recipe data. Every string in it points into `backing`, so the
    /// whole recipe costs one allocation instead of one per name and unit.
    recipe: Recipe = .{},
    /// The comment-stripped body every string in `recipe` points into.
    ///
    /// Owned by the same allocator and released by `deinit`. Freeing it while
    /// `recipe` is live dangles every name, amount and unit.
    backing: []const u8 = "",
    diagnostic: ?Diagnostic = null,

    pub fn isOk(self: Result) bool {
        return self.diagnostic == null;
    }

    /// Release everything the adapter allocated. Safe on a failed result.
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        if (self.markdown.len > 0) allocator.free(self.markdown);
        if (self.backing.len > 0) allocator.free(self.backing);
        if (self.recipe.ingredients.len > 0) allocator.free(self.recipe.ingredients);
        if (self.recipe.cookware.len > 0) allocator.free(self.recipe.cookware);
        if (self.recipe.timers.len > 0) allocator.free(self.recipe.timers);
    }
};

const ConvertError = error{InvalidCooklang} || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Line and text helpers
// ---------------------------------------------------------------------------

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

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Record a refusal. `column` is already 1-based, matching `textile.zig`'s
/// `reject` exactly — two sibling adapters with the same helper name and
/// opposite column conventions is how a reader moving between them gets it
/// wrong.
fn reject(diag_out: *?Diagnostic, line: u32, column: usize, message: []const u8) ConvertError {
    diag_out.* = .{
        .line = line,
        .column = @intCast(column),
        .message = message,
    };
    return error.InvalidCooklang;
}

/// Escape one byte so author text cannot become document structure.
///
/// The set is derived from the engine Boris actually links — Oliver,
/// CommonMark 0.31.2 (652/652 conformance) plus GFM tables and the opted-in
/// heading-attribute, footnote, definition-list and strikethrough extensions
/// (`src/render.zig`). Most of the escaped punctuation is live there: `|` for
/// table cells, `#` for ATX headings, `-`/`+` for lists, `` ` `` for code
/// spans, `[`/`]` for links and images, `=` for setext underlines, and `~`
/// for both strikethrough (`~~x~~`) and the definition-list `~ ` marker. `^`
/// and `$` are inert in Oliver Markdown (no superscript, no math) and are
/// over-guarded to keep the adapter engine-agnostic. The `"` guard survives
/// from the old Apex renderer, whose fenced divs emitted `class="…"`
/// unescaped — `:::x"onmouseover="alert(1)` published
/// `<div class="x"onmouseover="alert(1)">`. Oliver has no fenced divs, so
/// that injection is closed by the renderer migration; the guard is harmless
/// under CommonMark and is kept for the same reason.
///
/// Block-only triggers (`:` for definition lists) are handled by
/// `appendLineStartGuard` instead: they are harmless mid-sentence, and
/// escaping every colon would litter the published corpus.
fn appendMarkdownByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, c: u8) !void {
    switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\\', '`', '*', '_', '{', '}', '[', ']', '#', '+', '-', '!', '|', '~', '^', '=', '$' => {
            try out.append(allocator, '\\');
            try out.append(allocator, c);
        },
        else => try out.append(allocator, c),
    }
}

/// True when the colon at `i` must be neutralized so author text cannot
/// assemble a definition-list marker.
///
/// Oliver's definition lists are Pandoc-style: a `: ` (or `~ `) marker at the
/// start of a line, at most three columns indented, directly after a term
/// paragraph. A mid-line colon is inert — the `term :: definition` form
/// Apex's `definition_list.c` recognized anywhere on a line does not exist
/// here. The pair guard is retained as defensive over-guarding: escaping a
/// colon that touches another is cheap, ordinary prose (`Note: rest the
/// dough`) stays untouched, and the adapter cannot regress if a future
/// engine reintroduces the `::` form.
///
/// The backward look is against `out`, not the input, because a pair can be
/// assembled across two spans where neither half can see it:
/// `Mix @salt:{1}: done` emits `salt:` from the ingredient name and `:` from
/// the following prose, producing `Mix salt:: done` while both input-local
/// checks say the colon is inert. Escaping the *second* colon of any pair,
/// however it was assembled, is enough to break it.
fn colonIsLive(out: *const std.ArrayList(u8), text: []const u8, i: usize) bool {
    if (i + 1 < text.len and text[i + 1] == ':') return true;
    return out.items.len > 0 and out.items[out.items.len - 1] == ':';
}

/// Escape author text, resolving the colon's context from the whole span.
fn appendMarkdownText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text, 0..) |c, i| {
        // A numeric character reference, not a backslash: Oliver recognizes
        // the definition-list marker on the raw source line, so an entity is
        // the uniformly safe form — it can never be read as a marker by any
        // line scan. Measured against the engine, not assumed.
        if (c == ':' and colonIsLive(out, text, i)) {
            try out.appendSlice(allocator, "&#58;");
            continue;
        }
        try appendMarkdownByte(out, allocator, c);
    }
}

/// Neutralize a line-initial sequence that would open a block construct,
/// returning the number of input bytes consumed.
///
/// The per-byte escaper cannot see position, and two constructs are live only
/// at the start of a line:
///
/// - `: term` is Oliver's Pandoc-style definition-list marker (a `: ` or `~ `
///   at line start, directly after a term paragraph).
/// - Digits followed by `.` or `)` are an ordered-list marker, so
///   `1998. Then bake.` opened a nested `<ol start="1998">` inside the step.
///
/// The colon uses a numeric character reference rather than a backslash:
/// Oliver recognizes the marker on the raw source line, so an entity is the
/// uniformly safe form — it can never be read as a marker by any line scan.
///
/// `=` and `$` need no case here: both are escaped as ordinary punctuation
/// everywhere, which already covers their line-initial forms (`=` is a live
/// setext underline under CommonMark; `$` is inert now that math was removed
/// with Apex).
fn appendLineStartGuard(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !usize {
    if (text.len == 0) return 0;
    if (text[0] == ':') {
        try out.appendSlice(allocator, "&#58;");
        return 1;
    }
    var digits: usize = 0;
    while (digits < text.len and std.ascii.isDigit(text[digits])) : (digits += 1) {}
    if (digits > 0 and digits < text.len and (text[digits] == '.' or text[digits] == ')')) {
        try out.appendSlice(allocator, text[0..digits]);
        try out.append(allocator, '\\');
        try out.append(allocator, text[digits]);
        return digits + 1;
    }
    return 0;
}

fn looksLikeRawHtml(text: []const u8, index: usize) bool {
    if (text[index] != '<' or index + 1 >= text.len) return false;
    const next = text[index + 1];
    return std.ascii.isAlphabetic(next) or next == '/' or next == '!' or next == '?';
}

// ---------------------------------------------------------------------------
// Comment stripping
// ---------------------------------------------------------------------------

/// Remove `[- block -]` and `-- line` comments, preserving every newline so
/// diagnostic line numbers still refer to the author's file.
fn stripComments(
    body: []const u8,
    allocator: std.mem.Allocator,
    diag_out: *?Diagnostic,
) ConvertError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line: u32 = 1;
    var column: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == '\n') {
            try out.append(allocator, '\n');
            line += 1;
            column = 0;
            i += 1;
            continue;
        }

        if (body[i] == '[' and i + 1 < body.len and body[i + 1] == '-') {
            const open_line = line;
            const open_column = column;
            var j = i + 2;
            while (j + 1 < body.len and !(body[j] == '-' and body[j + 1] == ']')) : (j += 1) {
                // Newlines inside a block comment are kept so later lines keep
                // their authored numbers.
                if (body[j] == '\n') {
                    try out.append(allocator, '\n');
                    line += 1;
                    column = 0;
                }
            }
            if (j + 1 >= body.len) {
                return reject(diag_out, open_line, open_column, "unterminated Cooklang block comment: `[-` without a closing `-]`");
            }
            i = j + 2;
            continue;
        }

        if (body[i] == '-' and i + 1 < body.len and body[i + 1] == '-') {
            while (i < body.len and body[i] != '\n') : (i += 1) {}
            continue;
        }

        try out.append(allocator, body[i]);
        column += 1;
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Token parsing
// ---------------------------------------------------------------------------

/// A delimited run — a `{quantity}` or a `(preparation)` — holding the inner
/// text and the index just past the closing delimiter.
const Delimited = struct {
    inner: []const u8,
    next: usize,
};

fn readBraced(
    text: []const u8,
    index: usize,
    line_no: u32,
    base_column: usize,
    diag_out: *?Diagnostic,
) ConvertError!?Delimited {
    if (index >= text.len or text[index] != '{') return null;
    var j = index + 1;
    while (j < text.len and text[j] != '}') : (j += 1) {
        if (text[j] == '{') {
            return reject(diag_out, line_no, base_column + j, "nested `{` in a Cooklang quantity is unsupported");
        }
    }
    if (j >= text.len) {
        return reject(diag_out, line_no, base_column + index, "unterminated Cooklang `{`: add the closing `}`");
    }
    return .{ .inner = text[index + 1 .. j], .next = j + 1 };
}

/// A `(...)` short-hand preparation starting at `index`, or null.
fn readParen(
    text: []const u8,
    index: usize,
    line_no: u32,
    base_column: usize,
    diag_out: *?Diagnostic,
) ConvertError!?Delimited {
    if (index >= text.len or text[index] != '(') return null;
    var j = index + 1;
    while (j < text.len and text[j] != ')') : (j += 1) {
        if (text[j] == '(') {
            return reject(diag_out, line_no, base_column + j, "nested `(` in a Cooklang preparation is unsupported");
        }
    }
    if (j >= text.len) {
        return reject(diag_out, line_no, base_column + index, "unterminated Cooklang `(`: add the closing `)`");
    }
    return .{ .inner = text[index + 1 .. j], .next = j + 1 };
}

fn splitQuantity(inner: []const u8) Quantity {
    if (std.mem.indexOfScalar(u8, inner, '%')) |at| {
        return .{
            .amount = std.mem.trim(u8, inner[0..at], " \t"),
            .unit = std.mem.trim(u8, inner[at + 1 ..], " \t"),
        };
    }
    return .{ .amount = std.mem.trim(u8, inner, " \t") };
}

/// True when punctuation at `i` ends a sentence rather than sitting inside a
/// token name.
///
/// Context matters: the `.` in `@./sauces/Hollandaise` and in `@milk{1.5%l}` is
/// part of the name or amount, while the `.` in `add @salt.` terminates the
/// sentence. Only punctuation followed by a space or end-of-line breaks a name.
fn isSentenceBreak(text: []const u8, i: usize) bool {
    return switch (text[i]) {
        ',', '.', ';', ':', '!', '?' => i + 1 == text.len or isAsciiSpace(text[i + 1]),
        else => false,
    };
}

/// True when the byte at `i` ends a brace-less single-word token name.
fn endsBareNameAt(text: []const u8, i: usize) bool {
    const c = text[i];
    if (isAsciiSpace(c)) return true;
    if (isSentenceBreak(text, i)) return true;
    return switch (c) {
        '{', '}', '(', ')', '[', ']', '"', '\'', '@', '#', '~' => true,
        else => false,
    };
}

const TokenName = struct {
    /// Name as authored, braces removed.
    text: []const u8,
    /// Index just past the name and any `{...}`.
    next: usize,
    quantity: Quantity = .{},
    /// True when the author used explicit `{}` or `{qty}` braces.
    braced: bool = false,
};

/// Index of the `{` that closes a multi-word token name, or null.
///
/// Cooklang lets a name contain spaces only when `{` marks where it ends. The
/// lookahead therefore stops at anything that cannot be inside a name: another
/// token sigil, sentence punctuation, or a bracket. Without those stops
/// `add @salt and @pepper{1}` would read `salt and @pepper` as one ingredient.
fn multiWordNameEnd(text: []const u8, start: usize) ?usize {
    var j = start;
    while (j < text.len) : (j += 1) {
        if (isSentenceBreak(text, j)) return null;
        switch (text[j]) {
            '{' => {
                // The `{` closes a name only when it touches it. Without this,
                // `add @salt into the {bowl}` read `salt into the` as the name
                // and `bowl` as its amount, deleting the prose between them
                // from the rendered step. A brace-less name is one word, and an
                // unrelated braced word later in the sentence is not part of it.
                if (j > start and isAsciiSpace(text[j - 1])) return null;
                return j;
            },
            '@', '#', '~', '(', ')', '[', ']', '}', '\t' => return null,
            else => {},
        }
    }
    return null;
}

/// Parse a `@`/`#`/`~` token name and optional `{quantity}`.
///
/// `sigil_index` points at the sigil; parsing starts at the byte after it.
fn readTokenName(
    text: []const u8,
    sigil_index: usize,
    line_no: u32,
    base_column: usize,
    diag_out: *?Diagnostic,
) ConvertError!TokenName {
    const name_start = sigil_index + 1;

    // Braced form: the name runs to the `{`, spaces included.
    if (multiWordNameEnd(text, name_start)) |brace_at| {
        const braced = (try readBraced(text, brace_at, line_no, base_column, diag_out)).?;
        return .{
            .text = std.mem.trimEnd(u8, text[name_start..brace_at], " \t"),
            .next = braced.next,
            .quantity = splitQuantity(braced.inner),
            .braced = true,
        };
    }

    // Brace-less form: a single word.
    var end = name_start;
    while (end < text.len and !endsBareNameAt(text, end)) : (end += 1) {}
    return .{ .text = text[name_start..end], .next = end };
}

/// True when a derived reference id is safe to publish as a wiki link.
///
/// The adapter turns a recipe reference into `[[id]]`, so the id must satisfy
/// two consumers, not one:
///
/// 1. `identity.validateEntityId` — rejects traversal, absolute paths,
///    whitespace, `#`, `?` and `%`.
/// 2. `wikilink.zig`'s entity-id grammar, which is narrower:
///    `[A-Za-z0-9/_.-]` only.
///
/// Checking only the first let two bugs through. A `|` was read by the wiki
/// parser as the label separator, so `@./index|Anything` published an edge to
/// `index` while the IR recorded `index|Anything` — a reference that did not
/// match the edge it created and was not joinable against `nodes[].id`. And a
/// non-ASCII id such as `@./sauces/café` passed this check only to fail later
/// as `EREFERENCESYNTAX`, quoting generated syntax the author never wrote at a
/// line they could not act on. Refusing here names the real cause.
fn referenceIdSafe(id: []const u8) bool {
    if (!identity.validateEntityId(id)) return false;
    for (id) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '/' or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Split a recipe reference into its entity id and display name.
///
/// `@./sauces/Hollandaise` is a reference to another recipe; the path is
/// relative to the content root, so the id drops the leading `./` and any
/// `.cook` extension.
///
/// The `./` prefix is REQUIRED, which is narrower than it looks. Treating any
/// name containing `/` as a reference turned an ordinary ingredient into a
/// synthesized wiki link: `@half/half{1%cup}` failed the build with
/// `EREFERENCEMISSING: wiki-link target "half/half" not found`, telling a
/// recipe author to fix a wiki link they never wrote. The spec gives one form
/// for a reference, so accept exactly that one.
fn recipeReference(name: []const u8) ?struct { id: []const u8, display: []const u8 } {
    if (!std.mem.startsWith(u8, name, "./")) return null;
    var id = name[2..];
    if (std.mem.endsWith(u8, id, ".cook")) id = id[0 .. id.len - ".cook".len];
    if (id.len == 0) return null;
    const display = if (std.mem.lastIndexOfScalar(u8, id, '/')) |at| id[at + 1 ..] else id;
    if (display.len == 0) return null;
    return .{ .id = id, .display = display };
}

// ---------------------------------------------------------------------------
// Conversion
// ---------------------------------------------------------------------------

const Converter = struct {
    allocator: std.mem.Allocator,
    ingredients: std.ArrayList(Ingredient) = .empty,
    cookware: std.ArrayList(Cookware) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    diagnostic: ?Diagnostic = null,

    fn deinit(self: *Converter) void {
        self.ingredients.deinit(self.allocator);
        self.cookware.deinit(self.allocator);
        self.timers.deinit(self.allocator);
    }

    /// Refuse a recipe that would publish an unbounded IR facet.
    fn checkCounts(self: *Converter, line_no: u32, base: usize) ConvertError!void {
        if (self.ingredients.items.len > max_ingredient_count) {
            return reject(&self.diagnostic, line_no, base, "too many ingredients in one recipe");
        }
        if (self.cookware.items.len > max_cookware_count) {
            return reject(&self.diagnostic, line_no, base, "too many cookware items in one recipe");
        }
        if (self.timers.items.len > max_timer_count) {
            return reject(&self.diagnostic, line_no, base, "too many timers in one recipe");
        }
    }

    /// Reject bytes in any author-controlled span the inline scanner skips.
    ///
    /// The scanner's guards run at the cursor, and `readTokenName` moves the
    /// cursor past a whole token — so a name, a `{quantity}`, a
    /// `(preparation)` and a section name were all unreachable by them. Every
    /// one of those spans reaches published output, so every one needs the same
    /// guard; `@x{1\r2}` emitted a raw CR into the Markdown.
    fn checkText(self: *Converter, text: []const u8, line_no: u32, base: usize) ConvertError!void {
        for (text, 0..) |c, offset| {
            if (c < 0x20 and c != '\t') {
                return reject(&self.diagnostic, line_no, base + offset, "control characters are unsupported in Cooklang bodies");
            }
            if (offset + 1 < text.len and ((c == '{' and text[offset + 1] == '{') or (c == '[' and text[offset + 1] == '['))) {
                return reject(&self.diagnostic, line_no, base + offset, "Boris macros, wiki links, and components are unsupported in Cooklang mode");
            }
            if (c == '<' and looksLikeRawHtml(text, offset)) {
                return reject(&self.diagnostic, line_no, base + offset, "raw HTML and executable components are unsupported in Cooklang mode");
            }
        }
    }

    /// Guard every span of one parsed token: name, amount and unit.
    fn checkToken(self: *Converter, token: TokenName, line_no: u32, base: usize) ConvertError!void {
        if (token.text.len > max_token_name_bytes) {
            return reject(&self.diagnostic, line_no, base, "Cooklang token name is too long");
        }
        try self.checkText(token.text, line_no, base);
        try self.checkText(token.quantity.amount, line_no, base);
        try self.checkText(token.quantity.unit, line_no, base);
    }

    /// Convert one step line's inline markup, appending display text to `out`
    /// and recording every token in the recipe accumulators.
    fn convertStepLine(
        self: *Converter,
        out: *std.ArrayList(u8),
        text: []const u8,
        line_no: u32,
        /// 1-based column of `text[0]` in the author's line. `text` has had its
        /// leading indentation trimmed, so without this every diagnostic column
        /// on an indented line pointed that many bytes too far left.
        base_column: usize,
        /// Whether another line follows in this block. A forced line break with
        /// nothing after it has nothing to break to.
        has_next_line: bool,
    ) ConvertError!void {
        const allocator = self.allocator;
        // A block construct is only meaningful at the start of a line, which
        // the per-byte escaper cannot see.
        var i: usize = try appendLineStartGuard(out, allocator, text);
        while (i < text.len) {
            const c = text[i];

            if (c < 0x20 and c != '\t') {
                return reject(&self.diagnostic, line_no, base_column + i, "control characters are unsupported in Cooklang bodies");
            }
            if (i + 1 < text.len and ((c == '{' and text[i + 1] == '{') or (c == '[' and text[i + 1] == '['))) {
                return reject(&self.diagnostic, line_no, base_column + i, "Boris macros, wiki links, and components are unsupported in Cooklang mode");
            }
            if (c == '<' and looksLikeRawHtml(text, i)) {
                return reject(&self.diagnostic, line_no, base_column + i, "raw HTML and executable components are unsupported in Cooklang mode");
            }

            if (c == '@') {
                const token = try readTokenName(text, i, line_no, base_column, &self.diagnostic);
                if (token.text.len == 0) {
                    return reject(&self.diagnostic, line_no, base_column + i, "Cooklang ingredient name must not be empty");
                }
                try self.checkToken(token, line_no, i + 1);
                var next = token.next;
                var preparation: []const u8 = "";
                if (try readParen(text, next, line_no, base_column, &self.diagnostic)) |paren| {
                    preparation = paren.inner;
                    next = paren.next;
                }
                try self.checkText(preparation, line_no, i + 1);

                if (recipeReference(token.text)) |ref| {
                    if (!referenceIdSafe(ref.id)) {
                        return reject(&self.diagnostic, line_no, base_column + i, "Cooklang recipe reference is not a valid page id: remove traversal, whitespace, and `|`, `[`, `]`, `#`, `?`, `%`");
                    }
                    try self.ingredients.append(allocator, .{
                        .name = ref.display,
                        .quantity = token.quantity,
                        .preparation = preparation,
                        .recipe_ref = ref.id,
                    });
                    try self.checkCounts(line_no, base_column + i);
                    try appendMarkdownText(out, allocator, ref.display);
                } else {
                    try self.ingredients.append(allocator, .{
                        .name = token.text,
                        .quantity = token.quantity,
                        .preparation = preparation,
                    });
                    try self.checkCounts(line_no, base_column + i);
                    try appendMarkdownText(out, allocator, token.text);
                }
                i = next;
                continue;
            }

            if (c == '#') {
                const token = try readTokenName(text, i, line_no, base_column, &self.diagnostic);
                if (token.text.len == 0) {
                    return reject(&self.diagnostic, line_no, base_column + i, "Cooklang cookware name must not be empty");
                }
                try self.checkToken(token, line_no, i + 1);
                try self.cookware.append(allocator, .{ .name = token.text, .quantity = token.quantity });
                try self.checkCounts(line_no, base_column + i);
                try appendMarkdownText(out, allocator, token.text);
                i = token.next;
                continue;
            }

            if (c == '~') {
                const token = try readTokenName(text, i, line_no, base_column, &self.diagnostic);
                // `~{}` satisfied "braced" while carrying neither a name nor a
                // duration, so it recorded an empty timer and rendered nothing.
                if (token.text.len == 0 and token.quantity.isEmpty()) {
                    return reject(&self.diagnostic, line_no, base_column + i, "Cooklang timer needs a name or a `{duration}`");
                }
                try self.checkToken(token, line_no, i + 1);
                try self.timers.append(allocator, .{ .name = token.text, .quantity = token.quantity });
                try self.checkCounts(line_no, base_column + i);
                // A timer reads as its duration; the name exists for app
                // notifications, so it is only shown when there is no duration.
                if (token.quantity.isEmpty()) {
                    try appendMarkdownText(out, allocator, token.text);
                } else {
                    try appendQuantityText(out, allocator, token.quantity);
                }
                i = token.next;
                continue;
            }

            // A trailing backslash is Cooklang's forced line break, and
            // CommonMark spells a hard break the same way, so it passes through
            // as itself. With no following line there is nothing to break to,
            // and a hard break at the end of a block rendered as a visible
            // literal backslash — so it is dropped instead.
            if (c == '\\' and i + 1 == text.len) {
                if (has_next_line) try out.append(allocator, '\\');
                i += 1;
                continue;
            }

            if (c == ':' and colonIsLive(out, text, i)) {
                try out.appendSlice(allocator, "&#58;");
                i += 1;
                continue;
            }
            try appendMarkdownByte(out, allocator, c);
            i += 1;
        }
    }
};

/// `2 kg`, `2`, `kg`, or nothing — always with single spaces.
fn appendQuantityText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, quantity: Quantity) !void {
    if (quantity.amount.len > 0) {
        try appendMarkdownText(out, allocator, quantity.amount);
        if (quantity.unit.len > 0) try out.append(allocator, ' ');
    }
    if (quantity.unit.len > 0) try appendMarkdownText(out, allocator, quantity.unit);
}

const BlockKind = enum { section, note, step };

fn classifyBlock(first_line: []const u8) BlockKind {
    const trimmed = std.mem.trimStart(u8, first_line, " \t");
    if (trimmed.len > 0 and trimmed[0] == '=') return .section;
    if (trimmed.len > 0 and trimmed[0] == '>') return .note;
    return .step;
}

/// `= Dough`, `== Filling ==` and `=Dough=` all name the section `Dough`.
fn sectionName(line: []const u8) []const u8 {
    var name = std.mem.trim(u8, line, " \t");
    name = std.mem.trimStart(u8, name, "=");
    name = std.mem.trimEnd(u8, name, "=");
    return std.mem.trim(u8, name, " \t");
}

/// Adapt a Cooklang body to Markdown and extract its structured recipe.
///
/// The rendered document is deterministic: an `## Ingredients` list, then an
/// `## Cookware` list, then `## Method`. Empty groups are omitted entirely
/// rather than rendered as an empty heading. Author sections become `###`
/// headings inside Method, so a step's position is never ambiguous.
pub fn toMarkdown(body: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!Result {
    var diagnostic: ?Diagnostic = null;

    const clean = stripComments(body, allocator, &diagnostic) catch |err| switch (err) {
        error.InvalidCooklang => return .{ .diagnostic = diagnostic.? },
        error.OutOfMemory => return error.OutOfMemory,
    };
    // `clean` becomes the result's backing buffer on success and is released on
    // every other path. One flag, one `defer` — no per-branch free to forget.
    var clean_escapes = false;
    defer if (!clean_escapes) allocator.free(clean);

    var converter: Converter = .{ .allocator = allocator };
    var converter_escapes = false;
    defer if (!converter_escapes) converter.deinit();

    // Method is rendered after the ingredient and cookware lists, but the
    // tokens are only known once every step has been walked, so Method is built
    // into its own buffer first and appended after.
    var method: std.ArrayList(u8) = .empty;
    defer method.deinit(allocator);

    renderBlocks(&converter, &method, clean) catch |err| switch (err) {
        error.InvalidCooklang => return .{ .diagnostic = converter.diagnostic.? },
        error.OutOfMemory => return error.OutOfMemory,
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (converter.ingredients.items.len > 0) {
        try out.appendSlice(allocator, "## Ingredients\n\n");
        for (converter.ingredients.items) |item| {
            try out.appendSlice(allocator, "- ");
            if (item.isRecipeRef()) {
                // A recipe reference becomes a real wiki link, so the graph
                // gets a validated edge and a broken reference fails the build
                // instead of rendering as dead prose. The adapter emits Boris
                // syntax here; author-written `[[` is still refused above.
                try out.appendSlice(allocator, "[[");
                try out.appendSlice(allocator, item.recipe_ref);
                try out.appendSlice(allocator, "]]");
            } else {
                try appendMarkdownText(&out, allocator, item.name);
            }
            if (!item.quantity.isEmpty()) {
                try out.appendSlice(allocator, " — ");
                try appendQuantityText(&out, allocator, item.quantity);
            }
            if (item.preparation.len > 0) {
                try out.appendSlice(allocator, " (");
                try appendMarkdownText(&out, allocator, item.preparation);
                try out.append(allocator, ')');
            }
            try out.append(allocator, '\n');
        }
        try out.append(allocator, '\n');
    }

    if (converter.cookware.items.len > 0) {
        try out.appendSlice(allocator, "## Cookware\n\n");
        for (converter.cookware.items) |item| {
            try out.appendSlice(allocator, "- ");
            try appendMarkdownText(&out, allocator, item.name);
            if (!item.quantity.isEmpty()) {
                try out.appendSlice(allocator, " — ");
                try appendQuantityText(&out, allocator, item.quantity);
            }
            try out.append(allocator, '\n');
        }
        try out.append(allocator, '\n');
    }

    if (method.items.len > 0) {
        try out.appendSlice(allocator, "## Method\n\n");
        try out.appendSlice(allocator, method.items);
    }

    const markdown = try out.toOwnedSlice(allocator);
    errdefer allocator.free(markdown);
    const ingredients = try converter.ingredients.toOwnedSlice(allocator);
    errdefer allocator.free(ingredients);
    const cookware = try converter.cookware.toOwnedSlice(allocator);
    errdefer allocator.free(cookware);
    const timers = try converter.timers.toOwnedSlice(allocator);

    clean_escapes = true;
    converter_escapes = true;
    return .{
        .markdown = markdown,
        .backing = clean,
        .recipe = .{
            .ingredients = ingredients,
            .cookware = cookware,
            .timers = timers,
        },
    };
}

/// Walk the body block by block, appending Method markdown and collecting
/// tokens. Every rejection sets `converter.diagnostic`.
fn renderBlocks(
    converter: *Converter,
    method: *std.ArrayList(u8),
    clean: []const u8,
) ConvertError!void {
    const allocator = converter.allocator;
    var step_number: usize = 0;
    var cursor: usize = 0;
    var line_no: u32 = 1;

    while (cursor < clean.len) {
        const line = readLine(clean, cursor);
        if (isBlank(line.text)) {
            cursor = line.next;
            line_no += 1;
            continue;
        }

        const block_start = cursor;
        const block_line = line_no;
        var block_end = cursor;
        var block_lines: u32 = 0;
        while (block_end < clean.len) {
            const candidate = readLine(clean, block_end);
            if (isBlank(candidate.text)) break;
            block_end = candidate.next;
            block_lines += 1;
        }

        const first = readLine(clean, block_start).text;
        switch (classifyBlock(first)) {
            .section => {
                const name = sectionName(first);
                if (name.len == 0) {
                    return reject(&converter.diagnostic, block_line, 1, "Cooklang section needs a name between its `=` markers");
                }
                // A section name reaches an `###` heading, so it needs the same
                // guard as any other author-controlled span.
                try converter.checkText(name, block_line, 0);
                try method.appendSlice(allocator, "### ");
                try appendMarkdownText(method, allocator, name);
                try method.appendSlice(allocator, "\n\n");
                // Numbering restarts so each section reads as its own procedure.
                step_number = 0;
                // A section header owns only its own line. Further lines in the
                // same block are the section's first step.
                const after_header = readLine(clean, block_start).next;
                if (after_header < block_end) {
                    try convertOneStep(converter, method, clean, after_header, block_end, block_line + 1, &step_number);
                }
            },
            .note => {
                var at = block_start;
                var at_line = block_line;
                var first_note_line = true;
                try method.appendSlice(allocator, "> ");
                while (at < block_end) {
                    const note_line = readLine(clean, at);
                    // Each note line may or may not repeat the `>` marker.
                    const stripped = blk: {
                        const t = std.mem.trimStart(u8, note_line.text, " \t");
                        break :blk if (t.len > 0 and t[0] == '>') std.mem.trimStart(u8, t[1..], " \t") else t;
                    };
                    if (!first_note_line) try method.appendSlice(allocator, "\n> ");
                    // `stripped` points into `note_line.text`, so the offset
                    // between them is exactly the bytes trimmed off the front.
                    const note_base = (@intFromPtr(stripped.ptr) - @intFromPtr(note_line.text.ptr)) + 1;
                    try converter.convertStepLine(method, stripped, at_line, note_base, note_line.next < block_end);
                    first_note_line = false;
                    at = note_line.next;
                    at_line += 1;
                }
                try method.appendSlice(allocator, "\n\n");
            },
            .step => {
                try convertOneStep(converter, method, clean, block_start, block_end, block_line, &step_number);
            },
        }

        cursor = block_end;
        line_no += block_lines;
    }
}

/// Render one step block as a single ordered-list item.
fn convertOneStep(
    converter: *Converter,
    method: *std.ArrayList(u8),
    clean: []const u8,
    block_start: usize,
    block_end: usize,
    block_line: u32,
    step_number: *usize,
) ConvertError!void {
    const allocator = converter.allocator;
    step_number.* += 1;
    var number_buf: [24]u8 = undefined;
    const label = std.fmt.bufPrint(&number_buf, "{d}. ", .{step_number.*}) catch unreachable;
    try method.appendSlice(allocator, label);

    var at = block_start;
    var at_line = block_line;
    var first_line = true;
    while (at < block_end) {
        const line = readLine(clean, at);
        if (!first_line) {
            // Continuation lines are indented under the list marker so a step
            // that wraps cannot be read as a new block.
            try method.appendSlice(allocator, "\n   ");
        }
        const trimmed = std.mem.trimStart(u8, line.text, " \t");
        const base_column = (@intFromPtr(trimmed.ptr) - @intFromPtr(line.text.ptr)) + 1;
        try converter.convertStepLine(method, trimmed, at_line, base_column, line.next < block_end);
        first_line = false;
        at = line.next;
        at_line += 1;
    }
    try method.appendSlice(allocator, "\n\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectMarkdown(body: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    const result = try toMarkdown(body, gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings(want, result.markdown);
}

/// Every test releases through the public contract, so a leak here is a leak a
/// caller would hit too.
fn freeResult(gpa: std.mem.Allocator, result: Result) void {
    result.deinit(gpa);
}

test "a single-word ingredient needs no braces" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Then add @salt and pepper to taste.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 1), result.recipe.ingredients.len);
    try std.testing.expectEqualStrings("salt", result.recipe.ingredients[0].name);
    try std.testing.expect(result.recipe.ingredients[0].quantity.isEmpty());
    try std.testing.expectEqualStrings(
        "## Ingredients\n\n- salt\n\n## Method\n\n1. Then add salt and pepper to taste.\n\n",
        result.markdown,
    );
}

test "braces end a multi-word ingredient name" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Add @ground black pepper{} to taste.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 1), result.recipe.ingredients.len);
    try std.testing.expectEqualStrings("ground black pepper", result.recipe.ingredients[0].name);
}

test "quantity and unit are captured as authored" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Place @bacon strips{1%kg} and @syrup{1/2%tbsp} down.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 2), result.recipe.ingredients.len);
    try std.testing.expectEqualStrings("1", result.recipe.ingredients[0].quantity.amount);
    try std.testing.expectEqualStrings("kg", result.recipe.ingredients[0].quantity.unit);
    // A fraction stays a fraction: no numeric model, so no rounding.
    try std.testing.expectEqualStrings("1/2", result.recipe.ingredients[1].quantity.amount);
    try std.testing.expectEqualStrings("tbsp", result.recipe.ingredients[1].quantity.unit);
}

test "cookware and timers are extracted and read naturally" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Lay them on a #baking sheet{} in the #oven. Bake for ~{25%minutes}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 2), result.recipe.cookware.len);
    try std.testing.expectEqualStrings("baking sheet", result.recipe.cookware[0].name);
    try std.testing.expectEqualStrings("oven", result.recipe.cookware[1].name);
    try std.testing.expectEqual(@as(usize, 1), result.recipe.timers.len);
    try std.testing.expectEqualStrings("25", result.recipe.timers[0].quantity.amount);
    // The timer renders as its duration, not as markup.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "Bake for 25 minutes.") != null);
}

test "a named timer keeps its name for notifications but still reads as a duration" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Boil @eggs{2} for ~eggs{3%minutes}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings("eggs", result.recipe.timers[0].name);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "for 3 minutes.") != null);
}

test "short-hand preparation is captured and shown in the ingredient list" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Mix @onion{1}(peeled and finely chopped) into paste.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings("peeled and finely chopped", result.recipe.ingredients[0].preparation);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "- onion — 1 (peeled and finely chopped)") != null);
    // The preparation is list-only; the step keeps reading as a sentence.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "1. Mix onion into paste.") != null);
}

test "a recipe reference becomes a validated wiki link" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Pour over with @./sauces/Hollandaise{150%g}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expect(result.recipe.ingredients[0].isRecipeRef());
    try std.testing.expectEqualStrings("sauces/Hollandaise", result.recipe.ingredients[0].recipe_ref);
    try std.testing.expectEqualStrings("Hollandaise", result.recipe.ingredients[0].name);
    // The wiki link is what makes the reference a graph edge rather than prose.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "- [[sauces/Hollandaise]] — 150 g") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "1. Pour over with Hollandaise.") != null);
}

test "steps are numbered and sections restart the numbering" {
    try expectMarkdown(
        \\= Dough
        \\
        \\Mix it.
        \\
        \\== Filling ==
        \\
        \\Combine it.
        \\
    ,
        "## Method\n\n### Dough\n\n1. Mix it.\n\n### Filling\n\n1. Combine it.\n\n",
    );
}

test "a blank line separates steps" {
    try expectMarkdown(
        "A step,\nthe same step.\n\nA different step.\n",
        "## Method\n\n1. A step,\n   the same step.\n\n2. A different step.\n\n",
    );
}

test "a trailing backslash is a hard break in both languages" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Lay out the @rice paper{1}.\\\nTop with @avocado{1/2}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // Cooklang's forced break and CommonMark's hard break are the same
    // character, so it survives instead of being escaped to a literal.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "rice paper.\\\n") != null);
}

test "notes become blockquotes" {
    // `!` is escaped for the same reason `textile.zig` escapes it: unescaped it
    // pairs with a following `[` into an image.
    try expectMarkdown(
        "> Don't burn the roux!\n\nStir it.\n",
        "## Method\n\n> Don't burn the roux\\!\n\n1. Stir it.\n\n",
    );
}

test "line and block comments are removed" {
    try expectMarkdown(
        "Mash it -- or boil first.\n",
        "## Method\n\n1. Mash it \n\n",
    );
    try expectMarkdown(
        "Slowly add milk [- TODO litres -], keep mixing.\n",
        "## Method\n\n1. Slowly add milk , keep mixing.\n\n",
    );
}

test "a comment cannot hide a line's authored number from a later diagnostic" {
    const gpa = std.testing.allocator;
    // The block comment spans two lines; the error is on the fourth.
    const body = "Step one [- a\ncomment -] continues.\n\nStep <script>two.\n";
    const result = try toMarkdown(body, gpa);
    try std.testing.expect(!result.isOk());
    try std.testing.expectEqual(@as(u32, 4), result.diagnostic.?.line);
}

test "author text cannot forge Markdown structure" {
    const gpa = std.testing.allocator;
    // Each of these would open a block or an inline construct if it reached the
    // document unescaped. `#` and `~` are absent on purpose: they are Cooklang
    // sigils, so a bare one is an authoring error, not literal text — see the
    // rejection cases below.
    const result = try toMarkdown("Use *emphasis* and | pipe and [brackets] and 5 < 7.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings(
        "## Method\n\n1. Use \\*emphasis\\* and \\| pipe and \\[brackets\\] and 5 &lt; 7.\n\n",
        result.markdown,
    );
}

test "a step cannot forge a list item or a heading" {
    const gpa = std.testing.allocator;
    // A leading `- ` would become a sibling bullet inside Method, silently
    // restructuring the document around it.
    const result = try toMarkdown("Wait.\n\n- not a bullet\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "2. \\- not a bullet") != null);
}

test "an ingredient name cannot forge Markdown structure either" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Add @evil *name*{1}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // The bullet must stay one bullet.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "- evil \\*name\\* — 1") != null);
}

test "a continuation line cannot forge a setext heading" {
    const gpa = std.testing.allocator;
    // `=====` under a step line promoted it to an <h1> inside the Method list
    // item. `=` is only meaningful at the start of a line, so the per-byte
    // escaper never saw it.
    const result = try toMarkdown("Whisk @eggs{2} well.\n=====\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // `=` is escaped as ordinary punctuation now, so the whole run is inert.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "\\=\\=\\=\\=\\=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "\n   =====") == null);
}

test "a continuation line cannot open a fenced div, definition list, or math block" {
    const gpa = std.testing.allocator;
    // Under Oliver, `: ` at line start is a live definition-list marker, so
    // a forged one must not survive; `$` (math) and a raw `"` are inert in
    // Oliver Markdown but stay guarded as defensive over-guarding. The `"`
    // guard dates to the Apex renderer, whose fenced divs emitted
    // `class="…"` unescaped — `:::x"onmouseover="alert(1)` on a continuation
    // line published `<div class="x"onmouseover="alert(1)">`.
    const cases = [_][]const u8{
        "Rest the dough.\n:::x\"onmouseover=\"alert(1)\n",
        "Terms\n: forged definition\n",
        "Bake it.\n$$\n",
    };
    for (cases) |body| {
        const result = try toMarkdown(body, gpa);
        try std.testing.expect(result.isOk());
        defer freeResult(gpa, result);
        // No continuation line may begin with a live block trigger.
        var it = std.mem.splitScalar(u8, result.markdown, '\n');
        while (it.next()) |line| {
            const t = std.mem.trimStart(u8, line, " \t");
            try std.testing.expect(!std.mem.startsWith(u8, t, ":"));
            try std.testing.expect(!std.mem.startsWith(u8, t, "$"));
        }
        // And no raw attribute quote survives anywhere.
        try std.testing.expect(std.mem.indexOfScalar(u8, result.markdown, '"') == null);
    }
}

test "the escape set covers every construct the linked engine enables" {
    const gpa = std.testing.allocator;
    // Derived from the engine Boris actually links — Oliver, CommonMark 0.31.2
    // plus GFM tables and the opted-in heading-attribute, footnote,
    // definition-list and strikethrough extensions. The invariant is that a
    // byte the engine can turn into structure never reaches output raw —
    // either the adapter refuses the body, or it escapes the byte. `#` and
    // `~` are refused because a bare sigil is an authoring error; the rest
    // are escaped (`^` and `$` are inert under Oliver and over-guarded to
    // keep the adapter engine-agnostic).
    // `:` is deliberately absent: see the next test.
    const live = "\"^=|~`*_{}[]#+-!<>&$";
    for (live) |c| {
        const body = try std.fmt.allocPrint(gpa, "Add @salt then {c} more.\n", .{c});
        defer gpa.free(body);
        const result = try toMarkdown(body, gpa);
        defer freeResult(gpa, result);
        if (!result.isOk()) continue; // Refused outright: safe.
        const method = result.markdown[std.mem.indexOf(u8, result.markdown, "## Method").?..];
        if (std.mem.indexOfScalar(u8, method, c)) |at| {
            // Raw only ever acceptable as the payload of our own escape, or
            // when it is the `&` that opens one of our entities.
            const escaped = at > 0 and method[at - 1] == '\\';
            const is_entity_amp = c == '&' and std.mem.startsWith(u8, method[at..], "&#") or
                std.mem.startsWith(u8, method[at..], "&amp;") or
                std.mem.startsWith(u8, method[at..], "&quot;") or
                std.mem.startsWith(u8, method[at..], "&lt;") or
                std.mem.startsWith(u8, method[at..], "&gt;");
            if (!escaped and !is_entity_amp) {
                std.debug.print("\nbyte '{c}' survived raw in: {s}\n", .{ c, method });
                return error.LiveByteSurvivedRaw;
            }
        }
    }
}

test "a colon is neutralized where it opens a block and left alone mid-sentence" {
    const gpa = std.testing.allocator;
    // Prose keeps its colon: mid-sentence a lone colon opens nothing, and
    // escaping every one would litter the published corpus.
    const plain = try toMarkdown("Note: rest it.\n", gpa);
    try std.testing.expect(plain.isOk());
    defer freeResult(gpa, plain);
    try std.testing.expect(std.mem.indexOf(u8, plain.markdown, "Note: rest it.") != null);

    // `term :: def` is a definition list ANYWHERE on a line — no block start,
    // no list context, no surrounding spaces required. The plainest possible
    // step was rewritten into <dl><dt>1. Reduce the sauce</dt><dd>…</dd>,
    // destroying the Method list item.
    const inline_form = try toMarkdown("Reduce the sauce :: then plate it.\n", gpa);
    try std.testing.expect(inline_form.isOk());
    defer freeResult(gpa, inline_form);
    // The invariant is that no literal `::` survives — escaping the second
    // colon of the pair is enough to break the separator scan.
    try std.testing.expect(std.mem.indexOf(u8, inline_form.markdown, "::") == null);
    try std.testing.expect(std.mem.indexOf(u8, inline_form.markdown, "&#58;") != null);

    // `a::b` with no spaces triggers it too.
    const tight = try toMarkdown("Mix a::b now.\n", gpa);
    try std.testing.expect(tight.isOk());
    defer freeResult(gpa, tight);
    try std.testing.expect(std.mem.indexOf(u8, tight.markdown, "::") == null);

    // And the line-initial kramdown form cannot open one either.
    const line_form = try toMarkdown("Terms\n: forged definition\n", gpa);
    try std.testing.expect(line_form.isOk());
    defer freeResult(gpa, line_form);
    try std.testing.expect(std.mem.indexOf(u8, line_form.markdown, "&#58; forged definition") != null);
}

test "a colon pair assembled across two spans is still broken" {
    const gpa = std.testing.allocator;
    // Neither half can see the pair: `salt:` comes from the ingredient name and
    // the second colon from the prose after `}`, so an input-local adjacency
    // test called both inert and `Mix salt:: done` forged a <dl>. The backward
    // look is therefore against the output buffer.
    for ([_][]const u8{ "Mix @salt:{1}: done\n", "Also a:@:x{1} here\n" }) |body| {
        const result = try toMarkdown(body, gpa);
        try std.testing.expect(result.isOk());
        defer freeResult(gpa, result);
        try std.testing.expect(std.mem.indexOf(u8, result.markdown, "::") == null);
    }
}

test "a continuation line cannot forge a nested ordered list" {
    const gpa = std.testing.allocator;
    // `1998. Then bake.` opened <ol start="1998"> inside the step.
    const result = try toMarkdown("Rest the dough.\n1998. Then bake.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "1998\\. Then bake.") != null);
}

test "the adapter owns step numbering, so an authored marker stays literal" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("First.\n\n2. Second.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // The emitted marker is the adapter's `2. `; the author's is escaped.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "2. 2\\. Second.") != null);
}

test "the recipe facet is bounded like the relations facet it mirrors" {
    const gpa = std.testing.allocator;
    // Unbounded, this facet is an amplifier: it is the first thing to copy
    // author text verbatim into graph.json, so a small file could publish tens
    // of megabytes of IR from one page.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..max_ingredient_count + 2) |_| try body.appendSlice(gpa, "@a{1} ");
    try body.append(gpa, '\n');
    const result = try toMarkdown(body.items, gpa);
    defer freeResult(gpa, result);
    try std.testing.expect(!result.isOk());
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.?.message, "too many ingredients") != null);
}

test "an over-long token name is refused" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "Add @");
    for (0..max_token_name_bytes + 1) |_| try body.append(gpa, 'a');
    try body.appendSlice(gpa, "{1}.\n");
    const result = try toMarkdown(body.items, gpa);
    defer freeResult(gpa, result);
    try std.testing.expect(!result.isOk());
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.?.message, "too long") != null);
}

test "a timer with neither a name nor a duration is refused even when braced" {
    // `~{}` satisfied the braced check while carrying nothing, so it recorded
    // an empty timer in the IR and rendered as nothing at all.
    const result = try toMarkdown("Wait ~{} then serve.\n", std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.isOk());
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.?.message, "timer needs a name") != null);
}

test "a forced break at the end of a step is dropped, not rendered literally" {
    const gpa = std.testing.allocator;
    // A hard break with no following line rendered as a visible backslash.
    const result = try toMarkdown("Serve at once.\\\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "Serve at once.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "\\\n") == null);

    // With a following line it is still a real hard break.
    const wrapped = try toMarkdown("Top with avocado,\\\nthen shrimp.\n", gpa);
    try std.testing.expect(wrapped.isOk());
    defer freeResult(gpa, wrapped);
    try std.testing.expect(std.mem.indexOf(u8, wrapped.markdown, "avocado,\\\n") != null);
}

test "this adapter escapes at least everything the Textile adapter escapes" {
    // Two sibling adapters escaping author text differently would give the same
    // input two security postures. The sets are not equal on purpose — each
    // adapter's set is calibrated to its own risk surface — but this one must
    // never escape LESS. A prose comment claiming "the set matches
    // textile.zig" is what let that drift go unchecked; this is the same
    // claim as a gate.
    const gpa = std.testing.allocator;
    const textile = @import("textile.zig");
    for (0..128) |b| {
        const c: u8 = @intCast(b);
        if (c < 0x20) continue; // Refused upstream by both adapters.
        const input = [_]u8{ 'x', c, 'y' };

        const theirs = try textile.toMarkdown(&input, gpa);
        if (!theirs.isOk()) continue;
        defer gpa.free(theirs.markdown);

        var mine: std.ArrayList(u8) = .empty;
        defer mine.deinit(gpa);
        try appendMarkdownText(&mine, gpa, &input);

        // If Textile altered the byte, this adapter must alter it too.
        const they_escaped = !std.mem.eql(u8, theirs.markdown, &input);
        const we_escaped = !std.mem.eql(u8, mine.items, &input);
        if (they_escaped and !we_escaped) {
            std.debug.print("\nbyte 0x{X:0>2} ('{c}') escaped by textile but not here\n", .{ c, c });
            return error.EscapeSetRegressed;
        }
    }
}

test "guards apply inside a token name and a preparation, not just step text" {
    // `readTokenName` moves the cursor past a whole token, so these bytes were
    // never reaching the inline scanner's guards.
    const cases = [_][]const u8{
        "Add @spice\x01mix{1}.\n",
        "Add @onion{1}(chop\x01ped).\n",
        "Stir with #la\x01dle{}.\n",
        "Wait ~ti\x01mer{1%min}.\n",
        "Add @na<script>me{1}.\n",
        "Add @ev{{il}}x{1}.\n",
    };
    for (cases) |body| {
        const result = try toMarkdown(body, std.testing.allocator);
        try std.testing.expect(!result.isOk());
    }
}

test "a recipe reference must satisfy the wiki-link grammar, not just entity ids" {
    const gpa = std.testing.allocator;
    // `identity.validateEntityId` accepts these; `wikilink.zig` does not, and
    // the failure used to surface as EREFERENCESYNTAX quoting generated syntax.
    for ([_][]const u8{ "Pour @./sauces/café{1}.\n", "Pour @./a b/c{1}.\n" }) |body| {
        const result = try toMarkdown(body, gpa);
        try std.testing.expect(!result.isOk());
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.?.message, "not a valid page id") != null);
    }
}

test "the adapter refuses macros, wiki links, components and control characters" {
    const cases = [_]struct { body: []const u8, needle: []const u8 }{
        .{ .body = "{{include includes/a.md}}\n", .needle = "macros" },
        .{ .body = "See [[other/page]].\n", .needle = "wiki links" },
        .{ .body = "<Aside kind=\"tip\">x</Aside>\n", .needle = "components" },
        .{ .body = "Step with a \x01 byte.\n", .needle = "control characters" },
        .{ .body = "Add @flour{200%g to the bowl.\n", .needle = "unterminated Cooklang `{`" },
        .{ .body = "Mix @onion{1}(peeled into paste.\n", .needle = "unterminated Cooklang `(`" },
        .{ .body = "Start [- a comment that never ends.\n", .needle = "unterminated Cooklang block comment" },
        .{ .body = "Add @ to taste.\n", .needle = "ingredient name must not be empty" },
        .{ .body = "Use the # to stir.\n", .needle = "cookware name must not be empty" },
        .{ .body = "Wait for ~ then serve.\n", .needle = "timer needs a name" },
        .{ .body = "=  =\n\nStep.\n", .needle = "section needs a name" },
        // Reference-id forgery. Each of these once produced a wiki link whose
        // graph edge disagreed with the `recipeRef` recorded in the IR.
        .{ .body = "Pour @./index|Different Label{1}.\n", .needle = "not a valid page id" },
        .{ .body = "Pour @./../../etc/passwd{1}.\n", .needle = "not a valid page id" },
        .{ .body = "Pour @./a%2f b{1}.\n", .needle = "not a valid page id" },
    };
    for (cases) |case| {
        const result = try toMarkdown(case.body, std.testing.allocator);
        try std.testing.expect(!result.isOk());
        try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.?.message, case.needle) != null);
    }
}

test "references are preserved one per use rather than aggregated" {
    const gpa = std.testing.allocator;
    // Merging `200%g` with `1%cup` needs a unit model that v1 does not have,
    // so both references survive and a consumer decides what to do.
    const result = try toMarkdown("Mix @flour{200%g}.\n\nDust with @flour{1%cup}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 2), result.recipe.ingredients.len);
    try std.testing.expectEqualStrings("200", result.recipe.ingredients[0].quantity.amount);
    try std.testing.expectEqualStrings("1", result.recipe.ingredients[1].quantity.amount);
}

test "an empty body produces an empty document and an empty recipe" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings("", result.markdown);
    try std.testing.expect(result.recipe.isEmpty());
}

test "the adapter is deterministic" {
    const gpa = std.testing.allocator;
    const body = "= Dough\n\nMix @flour{200%g} and @water{100%ml} in a #bowl for ~{5%minutes}.\n";
    const a = try toMarkdown(body, gpa);
    try std.testing.expect(a.isOk());
    defer freeResult(gpa, a);
    const b = try toMarkdown(body, gpa);
    try std.testing.expect(b.isOk());
    defer freeResult(gpa, b);
    try std.testing.expectEqualStrings(a.markdown, b.markdown);
}

test "a brace-less name does not swallow a later braced word" {
    const gpa = std.testing.allocator;
    // `{bowl}` is unrelated prose, not this ingredient's quantity. Reading it as
    // one recorded `salt into the` with amount `bowl` and deleted the prose
    // between them from the rendered step.
    const result = try toMarkdown("Add @salt into the {bowl} now.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 1), result.recipe.ingredients.len);
    try std.testing.expectEqualStrings("salt", result.recipe.ingredients[0].name);
    try std.testing.expect(result.recipe.ingredients[0].quantity.isEmpty());
    // The prose survives, with the braces escaped as ordinary punctuation.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "Add salt into the \\{bowl\\} now.") != null);

    // A brace that touches the name still closes it, spaces and all.
    const touching = try toMarkdown("Add @ground black pepper{} to taste.\n", gpa);
    try std.testing.expect(touching.isOk());
    defer freeResult(gpa, touching);
    try std.testing.expectEqualStrings("ground black pepper", touching.recipe.ingredients[0].name);

    // And an anonymous timer's brace, which touches the sigil, still works.
    const timer = try toMarkdown("Bake for ~{25%minutes}.\n", gpa);
    try std.testing.expect(timer.isOk());
    defer freeResult(gpa, timer);
    try std.testing.expectEqualStrings("25", timer.recipe.timers[0].quantity.amount);
}
