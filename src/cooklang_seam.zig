//! Boris's Cooklang seam: parse with Oliver, render and validate here.
//!
//! Normative: `docs/contracts/cooklang-compatibility.md`.
//!
//! There is deliberately **no parser in Boris**. `toMarkdown` delegates the
//! `.cook` body to `oliver.cooklang.parse` (pinned as `.oliver_cooklang` in
//! `build.zig.zon`; see `docs/contracts/oliver-renderer.md`), which returns a
//! typed `Recipe` — steps, sections, notes and their ingredient/cookware/timer
//! parts — plus structured warnings for malformed structure. Oliver never
//! resolves recipe-reference paths and never parses YAML; both stay Boris
//! concerns (the frontmatter is split off by `parser.zig` before the body ever
//! reaches this module, exactly as `textile.zig` works).
//!
//! This module owns the two outputs the old adapter owned, but derives them
//! from Oliver's typed model instead of a second parser:
//!
//! 1. **Markdown** for the ordinary compile path — the body enters the same
//!    component/parser/renderer pipeline as any Markdown page. The rendered
//!    document shape is Boris policy, not a Cooklang-spec claim.
//! 2. **A `Recipe`** — the flat ingredient/cookware/timer IR facet, which is
//!    the whole reason a recipe format is worth supporting. It reaches the IR
//!    and the RAG corpus, where prose alone would be unqueryable.
//!
//! The seam also owns the **output-safety refusals** (control characters,
//! invalid recipe-reference ids, IR bounds) and maps Oliver's structural
//! warnings onto Boris's diagnostic pipeline. Author text is escaped on the
//! way out: recipe prose is untrusted input, and an unescaped `#` or `- `
//! would let a step forge a heading or a list item in the document that
//! contains it.

const std = @import("std");
const oliver_cooklang = @import("oliver_cooklang");

pub const adapter_identity = "boris-cooklang-seam-v1";

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
/// Oliver's typed model carries the same split (`quantity` before `%`, `units`
/// after), so the IR facet keeps the authored bytes verbatim.
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

/// Structured recipe data extracted from one `.cook` body, in the exact IR
/// 0.4 facet shape (see `docs/contracts/ir-schema.md`).
///
/// Every slice preserves authored order and holds one entry per reference. No
/// aggregation: merging two `@flour` references means adding `200%g` to
/// `1%cup`, which is not decidable without a unit model. A consumer that wants
/// a merged shopping list can group these; a consumer that wants fidelity has
/// it.
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
    /// Structured recipe data; every string in it is allocator-owned (duped
    /// from Oliver's borrowed slices) and released by `deinit`.
    recipe: Recipe = .{},
    /// Oliver's structural warnings (unclosed `{`, `(`, `[-`, frontmatter
    /// fence) mapped to body-relative positions. Messages are allocator-owned.
    warnings: []const Diagnostic = &.{},
    /// A Boris-side refusal, fatal like the old adapter's diagnostic. When
    /// set, `markdown`, `recipe` and `warnings` are empty.
    diagnostic: ?Diagnostic = null,

    pub fn isOk(self: Result) bool {
        return self.diagnostic == null;
    }

    /// Release everything the seam allocated. Safe on a failed result.
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        // Free per-string dupes and warning messages before their owning
        // array slices, which the loops below iterate.
        freeRecipeStrings(allocator, self.recipe);
        for (self.warnings) |warning| freeStr(allocator, warning.message);
        // The fatal diagnostic's message is a compile-time literal; it is
        // never freed.
        if (self.markdown.len > 0) allocator.free(self.markdown);
        if (self.warnings.len > 0) allocator.free(self.warnings);
        if (self.recipe.ingredients.len > 0) allocator.free(self.recipe.ingredients);
        if (self.recipe.cookware.len > 0) allocator.free(self.recipe.cookware);
        if (self.recipe.timers.len > 0) allocator.free(self.recipe.timers);
    }
};

fn freeStr(allocator: std.mem.Allocator, s: []const u8) void {
    if (s.len > 0) allocator.free(s);
}

fn freeRecipeStrings(allocator: std.mem.Allocator, recipe: Recipe) void {
    for (recipe.ingredients) |item| {
        freeStr(allocator, item.name);
        freeStr(allocator, item.quantity.amount);
        freeStr(allocator, item.quantity.unit);
        freeStr(allocator, item.preparation);
        freeStr(allocator, item.recipe_ref);
    }
    for (recipe.cookware) |item| {
        freeStr(allocator, item.name);
        freeStr(allocator, item.quantity.amount);
        freeStr(allocator, item.quantity.unit);
    }
    for (recipe.timers) |item| {
        freeStr(allocator, item.name);
        freeStr(allocator, item.quantity.amount);
        freeStr(allocator, item.quantity.unit);
    }
}

/// Duplicate a string only when it is non-empty; empty stays a zero-length
/// slice that `deinit` skips.
fn dupeStr(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (s.len == 0) return "";
    return allocator.dupe(u8, s);
}

pub const ConvertError = error{ InvalidCooklang, InputTooLarge } || std.mem.Allocator.Error;

/// Adapt a Cooklang body to Markdown and extract its structured recipe.
///
/// Parsing is Oliver's (`oliver.cooklang.parse`); everything after the parse
/// is this module's. The rendered document is deterministic: an
/// `## Ingredients` list, then a `## Cookware` list, then `## Method`. Empty
/// groups are omitted entirely rather than rendered as an empty heading.
/// Author sections become `###` headings inside Method, so a step's position
/// is never ambiguous.
///
/// `body` must be the frontmatter-split body (like `textile.toMarkdown`); the
/// callers split frontmatter first. Oliver borrows `body` for the duration of
/// the parse only — every string the seam retains is duped before the parse
/// result is released.
pub fn toMarkdown(body: []const u8, allocator: std.mem.Allocator) ConvertError!Result {
    var parsed = oliver_cooklang.cooklang.parse(allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InputTooLarge => return error.InputTooLarge,
    };
    defer parsed.deinit();
    return adapt(allocator, &parsed.recipe, parsed.diagnostics);
}

fn reject(diag_out: *?Diagnostic, line: u32, column: usize, message: []const u8) ConvertError {
    diag_out.* = .{
        .line = line,
        .column = @intCast(column),
        .message = message,
    };
    return error.InvalidCooklang;
}

// ---------------------------------------------------------------------------
// Markdown escaping (Boris policy, judged against the linked engine)
// ---------------------------------------------------------------------------

/// Escape one byte so author text cannot become document structure.
///
/// The set is judged against the engine Boris actually links, and that engine
/// changed: Oliver replaced ApexMarkdown Unified. Oliver is CommonMark 0.31.2
/// plus GFM tables and four opted-in extensions — heading attributes,
/// footnotes, definition lists and strikethrough. See
/// `docs/contracts/oliver-renderer.md`.
///
/// Measured against Oliver, these are live and this set is what closes them:
///
/// - `[` — a footnote reference (`[^1]`) and a link.
/// - `~` — GFM strikethrough (`~~x~~`). Also the timer sigil, so a bare one is
///   inert prose before it reaches here.
/// - `=` — a setext underline, which promotes the previous line to a heading.
/// - `#` `|` `` ` `` `*` `_` `-` `+` `!` — ordinary CommonMark block and inline
///   openers: headings, table cells, code spans, emphasis, list items, images.
/// - `{` `}` — a heading attribute list (`{#id .class}`).
/// - `&` `<` `>` — raw-HTML and entity interpretation.
///
/// `"`, `^` and `$` are no longer reachable as structure: they were live under
/// Apex's fenced divs, superscript and math, all of which Oliver does not have.
/// They are kept deliberately. Escaping them costs nothing under CommonMark and
/// keeps the seam from silently becoming unsafe if an extension is opted in
/// later — the same reasoning Boris applies to the `"` guard in
/// `docs/changelog.d/368-cooklang-input-format.md`.
///
/// The colon is not here: it is position-sensitive, so `appendLineStartGuard`
/// and `colonIsLive` own it.
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

/// True when the colon at `i` could pair into a definition-list separator.
///
/// Definition lists are still an opted-in Oliver extension, but only in the
/// line-initial `Term` + `: def` form, which `appendLineStartGuard` owns.
/// Verified against Oliver: `Reduce the sauce :: then plate it.` and `a::b`
/// both render as ordinary paragraphs.
///
/// The `::` form was Apex-specific. Its `find_def_separator` scanned the whole
/// line, so that plain step was rewritten into
/// `<dl><dt>1. Reduce the sauce</dt><dd>then plate it.</dd>`, destroying the
/// Method list item. This check is therefore **defence in depth on Oliver, not
/// a live requirement** — kept because it costs one comparison, it is invisible
/// in ordinary prose, and a dialect that scans for `::` again would otherwise
/// silently reopen the hole.
fn colonIsLive(out: *const std.ArrayList(u8), text: []const u8, i: usize) bool {
    if (i + 1 < text.len and text[i + 1] == ':') return true;
    return out.items.len > 0 and out.items[out.items.len - 1] == ':';
}

/// Escape author text, resolving the colon's context from the whole span.
fn appendMarkdownText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text, 0..) |c, i| {
        // A numeric character reference, not a backslash: under Apex the
        // definition-list and fenced-div passes ran before parsing and never
        // saw a backslash escape. An entity is inert to a preprocessor and to a
        // block parser alike, so it stays correct across both engines.
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
/// at the start of a line. Both were re-verified against Oliver:
///
/// - `: def` under a term line is the definition-list form, which Oliver still
///   opts into. `Term` followed by `: kramdown definition form` renders a real
///   `<dl>`, so this guard is load-bearing, not historical.
/// - Digits followed by `.` or `)` are an ordered-list marker: `1998. numbered`
///   renders `<ol start="1998">`, which inside a step would nest a list in it.
///
/// The colon uses a numeric character reference rather than a backslash. Under
/// Apex the definition-list pass ran before parsing and never saw a backslash
/// escape; an entity is inert to a preprocessor and to a block parser alike, so
/// it stays correct across both engines.
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

/// Append step text, normalizing any raw line break Oliver left in a text
/// value to a single space — the canonical join form. Oliver's spans can
/// cover commented bytes, and when a block comment ends exactly at a line
/// boundary the following newline byte survives into the value; without this
/// normalization the step would render a hard break the author did not write.
fn appendStepText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    var segments = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (segments.next()) |raw_seg| {
        var seg = raw_seg;
        // A segment that is joined to a following one has its trailing
        // whitespace trimmed so the join space does not double up. The last
        // segment keeps its bytes (the old adapter preserved the space before
        // a stripped line comment, and matching it keeps goldens stable).
        if (segments.peek() != null) {
            seg = std.mem.trimEnd(u8, seg, " \t\r");
        } else if (seg.len > 0 and seg[seg.len - 1] == '\r') {
            seg = seg[0 .. seg.len - 1];
        }
        if (!first) try out.append(allocator, ' ');
        first = false;
        try appendMarkdownText(out, allocator, seg);
    }
}

/// `2 kg`, `2`, `kg`, or nothing — always with single spaces.
fn appendQuantityText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, quantity: Quantity) !void {
    if (quantity.amount.len > 0) {
        try appendMarkdownText(out, allocator, quantity.amount);
        if (quantity.unit.len > 0) try out.append(allocator, ' ');
    }
    if (quantity.unit.len > 0) try appendMarkdownText(out, allocator, quantity.unit);
}

// ---------------------------------------------------------------------------
// Recipe-reference normalization and validation
// ---------------------------------------------------------------------------

/// Split a recipe reference into its entity id and display name.
///
/// `@./sauces/Hollandaise` is a reference to another recipe; the path is
/// relative to the content root, so the id drops the leading `./` and any
/// `.cook` extension. Oliver flags any name beginning `./`, `../` or `/`; the
/// `../` and `/` forms carry traversal or an absolute path and fail
/// `referenceIdSafe` below — the `./` form is the one the Cooklang spec
/// documents and the only one Boris accepts.
fn recipeReference(name: []const u8) ?struct { id: []const u8, display: []const u8 } {
    if (!std.mem.startsWith(u8, name, "./")) return null;
    var id = name[2..];
    if (std.mem.endsWith(u8, id, ".cook")) id = id[0 .. id.len - ".cook".len];
    if (id.len == 0) return null;
    const display = if (std.mem.lastIndexOfScalar(u8, id, '/')) |at| id[at + 1 ..] else id;
    if (display.len == 0) return null;
    return .{ .id = id, .display = display };
}

/// True when a derived reference id is safe to publish as a wiki link.
///
/// The seam turns a recipe reference into `[[id]]`, so the id must satisfy
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
    const identity = @import("identity.zig");
    if (!identity.validateEntityId(id)) return false;
    for (id) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '/' or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Seam conversion: walk Oliver's typed Recipe, render Markdown, collect the
// flat IR facet, and refuse what would publish unsafe output.
// ---------------------------------------------------------------------------

const Accumulator = struct {
    allocator: std.mem.Allocator,
    ingredients: std.ArrayList(Ingredient) = .empty,
    cookware: std.ArrayList(Cookware) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    warnings: std.ArrayList(Diagnostic) = .empty,
    diagnostic: ?Diagnostic = null,

    fn deinit(self: *Accumulator) void {
        self.ingredients.deinit(self.allocator);
        self.cookware.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
    }

    /// Free the per-item string dupes (used on the refusal path, where the
    /// arrays are discarded instead of promoted onto the result).
    fn freeStrings(self: *Accumulator) void {
        freeRecipeStrings(self.allocator, .{
            .ingredients = self.ingredients.items,
            .cookware = self.cookware.items,
            .timers = self.timers.items,
        });
    }

    /// Refuse a recipe that would publish an unbounded IR facet.
    fn checkCounts(self: *Accumulator, line: u32, column: usize) ConvertError!void {
        if (self.ingredients.items.len > max_ingredient_count) {
            return reject(&self.diagnostic, line, column, "too many ingredients in one recipe");
        }
        if (self.cookware.items.len > max_cookware_count) {
            return reject(&self.diagnostic, line, column, "too many cookware items in one recipe");
        }
        if (self.timers.items.len > max_timer_count) {
            return reject(&self.diagnostic, line, column, "too many timers in one recipe");
        }
    }
};

/// Refuse control characters in any author-controlled span that reaches
/// published output. Oliver's model already degraded malformed structure; this
/// is Boris's output-hygiene line, carried over from the old adapter.
fn checkControlChars(
    recipe: *const oliver_cooklang.cooklang.Recipe,
    text: []const u8,
    offset: usize,
    accumulator: *Accumulator,
) ConvertError!void {
    for (text, 0..) |c, i| {
        // `\n` and `\r` are line structure (Oliver can leave a raw newline in
        // a text value when a block comment ends at a line boundary), not
        // refusable controls; `appendStepText` normalizes them to joins.
        if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') {
            const lc = recipe.source.lineCol(@intCast(offset + i));
            return reject(&accumulator.diagnostic, lc.line, lc.column, "control characters are unsupported in Cooklang bodies");
        }
    }
}

/// Resolve one Oliver ingredient into its Boris IR form, refusing the
/// reference forms Boris cannot publish safely.
fn resolveIngredient(
    recipe: *const oliver_cooklang.cooklang.Recipe,
    src: oliver_cooklang.cooklang.Ingredient,
    accumulator: *Accumulator,
) ConvertError!Ingredient {
    const allocator = accumulator.allocator;
    if (src.is_recipe_reference) {
        const ref = recipeReference(src.name) orelse {
            const lc = recipe.source.lineCol(src.span.start);
            return reject(
                &accumulator.diagnostic,
                lc.line,
                lc.column,
                "Cooklang recipe reference is not a valid page id: use `./` plus a content-root-relative path without traversal, whitespace, or `|`, `[`, `]`, `#`, `?`, `%`",
            );
        };
        if (!referenceIdSafe(ref.id)) {
            const lc = recipe.source.lineCol(src.span.start);
            return reject(
                &accumulator.diagnostic,
                lc.line,
                lc.column,
                "Cooklang recipe reference is not a valid page id: remove traversal, whitespace, and `|`, `[`, `]`, `#`, `?`, `%`",
            );
        }
        return .{
            .name = try dupeStr(allocator, ref.display),
            .quantity = .{
                .amount = try dupeStr(allocator, src.quantity orelse ""),
                .unit = try dupeStr(allocator, src.units orelse ""),
            },
            .preparation = try dupeStr(allocator, src.preparation orelse ""),
            .recipe_ref = try dupeStr(allocator, ref.id),
        };
    }
    return .{
        .name = try dupeStr(allocator, src.name),
        .quantity = .{
            .amount = try dupeStr(allocator, src.quantity orelse ""),
            .unit = try dupeStr(allocator, src.units orelse ""),
        },
        .preparation = try dupeStr(allocator, src.preparation orelse ""),
    };
}

fn resolveCookware(
    recipe: *const oliver_cooklang.cooklang.Recipe,
    src: oliver_cooklang.cooklang.Cookware,
    accumulator: *Accumulator,
) ConvertError!Cookware {
    _ = recipe;
    const allocator = accumulator.allocator;
    // Cookware carries a quantity but no units in the Cooklang model; the IR
    // facet's `unit` stays empty for a cookware item.
    return .{
        .name = try dupeStr(allocator, src.name),
        .quantity = .{
            .amount = try dupeStr(allocator, src.quantity orelse ""),
            .unit = "",
        },
    };
}

fn resolveTimer(
    recipe: *const oliver_cooklang.cooklang.Recipe,
    src: oliver_cooklang.cooklang.Timer,
    accumulator: *Accumulator,
) ConvertError!Timer {
    const allocator = accumulator.allocator;
    // `~{}` — neither a name nor a duration — is an authoring error the old
    // adapter refused; an empty timer would otherwise reach the IR facet and
    // render as nothing.
    const quantity = src.quantity orelse "";
    if (src.name.len == 0 and quantity.len == 0) {
        const lc = recipe.source.lineCol(src.span.start);
        return reject(&accumulator.diagnostic, lc.line, lc.column, "Cooklang timer needs a name or a `{duration}`");
    }
    return .{
        .name = try dupeStr(allocator, src.name),
        .quantity = .{
            .amount = try dupeStr(allocator, quantity),
            .unit = try dupeStr(allocator, src.units orelse ""),
        },
    };
}

/// The display name of a recipe reference: the final path segment of the
/// authored name (`./sauces/Hollandaise` → `Hollandaise`). Reads Oliver's
/// borrowed slice; no allocation.
fn referenceDisplay(name: []const u8) []const u8 {
    const id = if (std.mem.lastIndexOfScalar(u8, name, '/')) |at| name[at + 1 ..] else name;
    if (std.mem.endsWith(u8, id, ".cook")) return id[0 .. id.len - ".cook".len];
    return id;
}

/// Render one step's parts into `out` while collecting the IR facet, reading
/// each token as the old adapter did: an ingredient or cookware item renders
/// as its name, and a timer renders as its duration (the name exists for app
/// notifications), so the prose keeps reading as a sentence.
fn renderStepParts(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    recipe: *const oliver_cooklang.cooklang.Recipe,
    step: oliver_cooklang.cooklang.Step,
    accumulator: *Accumulator,
) ConvertError!void {
    for (step.parts, 0..) |part, index| {
        switch (part) {
            .text => |text| {
                // A block construct is only meaningful at the start of a
                // rendered line. Oliver joins a step's continuation lines with
                // single spaces, so only the first part can open one. The
                // guard consumes leading bytes; the rest is escaped below.
                var guarded: usize = 0;
                if (index == 0) {
                    guarded = try appendLineStartGuard(out, allocator, text.text);
                }
                try checkControlChars(recipe, text.text, text.span.start, accumulator);
                try appendStepText(out, allocator, text.text[guarded..]);
            },
            .ingredient => |src| {
                if (src.name.len > max_token_name_bytes) {
                    const lc = recipe.source.lineCol(src.span.start);
                    return reject(&accumulator.diagnostic, lc.line, lc.column, "Cooklang token name is too long");
                }
                try checkControlChars(recipe, src.name, src.name_span.start, accumulator);
                try checkControlChars(recipe, src.quantity orelse "", src.quantity_span.start, accumulator);
                try checkControlChars(recipe, src.units orelse "", src.units_span.start, accumulator);
                try checkControlChars(recipe, src.preparation orelse "", src.preparation_span.start, accumulator);
                try collectIngredient(recipe, src, accumulator);
                if (src.is_recipe_reference) {
                    try appendMarkdownText(out, allocator, referenceDisplay(src.name));
                } else {
                    try appendMarkdownText(out, allocator, src.name);
                }
            },
            .cookware => |src| {
                if (src.name.len > max_token_name_bytes) {
                    const lc = recipe.source.lineCol(src.span.start);
                    return reject(&accumulator.diagnostic, lc.line, lc.column, "Cooklang token name is too long");
                }
                try checkControlChars(recipe, src.name, src.name_span.start, accumulator);
                try checkControlChars(recipe, src.quantity orelse "", src.quantity_span.start, accumulator);
                try accumulator.cookware.append(allocator, try resolveCookware(recipe, src, accumulator));
                const lc = recipe.source.lineCol(src.span.start);
                try accumulator.checkCounts(lc.line, lc.column);
                try appendMarkdownText(out, allocator, src.name);
            },
            .timer => |src| {
                if (src.name.len > max_token_name_bytes) {
                    const lc = recipe.source.lineCol(src.span.start);
                    return reject(&accumulator.diagnostic, lc.line, lc.column, "Cooklang token name is too long");
                }
                try checkControlChars(recipe, src.name, src.name_span.start, accumulator);
                try checkControlChars(recipe, src.quantity orelse "", src.quantity_span.start, accumulator);
                try checkControlChars(recipe, src.units orelse "", src.units_span.start, accumulator);
                const timer = try resolveTimer(recipe, src, accumulator);
                try accumulator.timers.append(allocator, timer);
                const lc = recipe.source.lineCol(src.span.start);
                try accumulator.checkCounts(lc.line, lc.column);
                // A timer reads as its duration; the name exists for app
                // notifications, so it is only shown when there is no duration.
                if (timer.quantity.isEmpty()) {
                    try appendMarkdownText(out, allocator, timer.name);
                } else {
                    try appendQuantityText(out, allocator, timer.quantity);
                }
            },
            .line_break => {
                // Cooklang's forced line break and CommonMark's hard break are
                // the same character: a `\` immediately before a line end.
                try out.appendSlice(allocator, "\\\n");
            },
        }
    }
}

/// Render one step block as a single ordered-list item.
fn renderStep(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    recipe: *const oliver_cooklang.cooklang.Recipe,
    step: oliver_cooklang.cooklang.Step,
    accumulator: *Accumulator,
    step_number: *usize,
) ConvertError!void {
    step_number.* += 1;
    var number_buf: [24]u8 = undefined;
    const label = std.fmt.bufPrint(&number_buf, "{d}. ", .{step_number.*}) catch unreachable;
    try out.appendSlice(allocator, label);
    try renderStepParts(out, allocator, recipe, step, accumulator);
    try out.appendSlice(allocator, "\n\n");
}

fn renderNote(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    recipe: *const oliver_cooklang.cooklang.Recipe,
    note: oliver_cooklang.cooklang.Note,
    accumulator: *Accumulator,
) ConvertError!void {
    try checkControlChars(recipe, note.text, note.span.start, accumulator);
    // A blockquote is only meaningful at the start of a rendered line; the
    // guard runs on the note body before the `> ` prefix is added.
    var guarded: std.ArrayList(u8) = .empty;
    defer guarded.deinit(allocator);
    const guard_n = try appendLineStartGuard(&guarded, allocator, note.text);
    try appendMarkdownText(&guarded, allocator, note.text[guard_n..]);
    try out.appendSlice(allocator, "> ");
    try out.appendSlice(allocator, guarded.items);
    try out.appendSlice(allocator, "\n\n");
}

/// Walk one block list, rendering into `out` and collecting the flat IR facet.
fn renderBlocks(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    recipe: *const oliver_cooklang.cooklang.Recipe,
    blocks: []const oliver_cooklang.cooklang.Block,
    accumulator: *Accumulator,
    step_number: *usize,
) ConvertError!void {
    for (blocks) |block| {
        switch (block) {
            .step => |step| {
                try renderStep(out, allocator, recipe, step, accumulator, step_number);
            },
            .section => |section| {
                if (section.name.len == 0) {
                    const lc = recipe.source.lineCol(section.span.start);
                    return reject(&accumulator.diagnostic, lc.line, lc.column, "Cooklang section needs a name between its `=` markers");
                }
                if (section.name.len > max_token_name_bytes) {
                    const lc = recipe.source.lineCol(section.name_span.start);
                    return reject(&accumulator.diagnostic, lc.line, lc.column, "Cooklang token name is too long");
                }
                try checkControlChars(recipe, section.name, section.name_span.start, accumulator);
                // A section name reaches an `###` heading, so it needs the same
                // guard as any other author-controlled span.
                try out.appendSlice(allocator, "### ");
                try appendMarkdownText(out, allocator, section.name);
                try out.appendSlice(allocator, "\n\n");
                // Numbering restarts so each section reads as its own procedure.
                step_number.* = 0;
                try renderBlocks(out, allocator, recipe, section.blocks, accumulator, step_number);
            },
            .note => |note| {
                try renderNote(out, allocator, recipe, note, accumulator);
            },
        }
    }
}

/// Append one ingredient to the IR facet, refusing the reference forms Boris
/// cannot publish safely and guarding the counts.
fn collectIngredient(
    recipe: *const oliver_cooklang.cooklang.Recipe,
    src: oliver_cooklang.cooklang.Ingredient,
    accumulator: *Accumulator,
) ConvertError!void {
    const resolved = try resolveIngredient(recipe, src, accumulator);
    try accumulator.ingredients.append(accumulator.allocator, resolved);
    const lc = recipe.source.lineCol(src.span.start);
    try accumulator.checkCounts(lc.line, lc.column);
}

/// Convert one parsed recipe into the Markdown document and the IR facet.
fn adapt(
    allocator: std.mem.Allocator,
    recipe: *const oliver_cooklang.cooklang.Recipe,
    oliver_diags: []const oliver_cooklang.diagnostic.Diagnostic,
) ConvertError!Result {
    var accumulator: Accumulator = .{ .allocator = allocator };
    defer accumulator.deinit();

    // Method is rendered after the ingredient and cookware lists, but the
    // tokens are only known once every block has been walked, so Method is
    // built into its own buffer first and appended after.
    var method: std.ArrayList(u8) = .empty;
    defer method.deinit(allocator);

    var step_number: usize = 0;
    renderBlocks(&method, allocator, recipe, recipe.blocks, &accumulator, &step_number) catch |err| switch (err) {
        error.InvalidCooklang => {
            // Refusals carry a fatal diagnostic. The partially-collected
            // facet is discarded; free its strings before returning.
            accumulator.freeStrings();
            return .{ .diagnostic = accumulator.diagnostic.? };
        },
        else => return err,
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (accumulator.ingredients.items.len > 0) {
        try out.appendSlice(allocator, "## Ingredients\n\n");
        for (accumulator.ingredients.items) |item| {
            try out.appendSlice(allocator, "- ");
            if (item.isRecipeRef()) {
                // A recipe reference becomes a real wiki link, so the graph
                // gets a validated edge and a broken reference fails the build
                // instead of rendering as dead prose. The seam emits Boris
                // syntax here; author-written `[[` is escaped as text above.
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

    if (accumulator.cookware.items.len > 0) {
        try out.appendSlice(allocator, "## Cookware\n\n");
        for (accumulator.cookware.items) |item| {
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

    // Oliver's structural warnings become Boris warnings, carrying Oliver's
    // stable code in the message so an author can look it up. Oliver reports
    // line/column against the body, exactly like the old adapter.
    var warnings: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (warnings.items) |w| freeStr(allocator, w.message);
        warnings.deinit(allocator);
    }
    for (oliver_diags) |d| {
        const message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ d.code, d.message });
        try warnings.append(allocator, .{
            .line = d.line,
            .column = d.column,
            .message = message,
        });
    }

    const markdown = try out.toOwnedSlice(allocator);
    errdefer allocator.free(markdown);
    const ingredients = try accumulator.ingredients.toOwnedSlice(allocator);
    errdefer allocator.free(ingredients);
    const cookware = try accumulator.cookware.toOwnedSlice(allocator);
    errdefer allocator.free(cookware);
    const timers = try accumulator.timers.toOwnedSlice(allocator);
    errdefer allocator.free(timers);
    const warning_list = try warnings.toOwnedSlice(allocator);

    return .{
        .markdown = markdown,
        .recipe = .{
            .ingredients = ingredients,
            .cookware = cookware,
            .timers = timers,
        },
        .warnings = warning_list,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn freeResult(gpa: std.mem.Allocator, result: Result) void {
    result.deinit(gpa);
}

test "seam: a single-word ingredient needs no braces" {
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

test "seam: braces end a multi-word ingredient name" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Add @ground black pepper{} to taste.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 1), result.recipe.ingredients.len);
    try std.testing.expectEqualStrings("ground black pepper", result.recipe.ingredients[0].name);
}

test "seam: quantity and unit are captured as authored" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Place @bacon strips{1%kg} and @syrup{1/2%tbsp} down.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 2), result.recipe.ingredients.len);
    try std.testing.expectEqualStrings("bacon strips", result.recipe.ingredients[0].name);
    try std.testing.expectEqualStrings("1", result.recipe.ingredients[0].quantity.amount);
    try std.testing.expectEqualStrings("kg", result.recipe.ingredients[0].quantity.unit);
    // A fraction stays a fraction: no numeric model, so no rounding.
    try std.testing.expectEqualStrings("1/2", result.recipe.ingredients[1].quantity.amount);
    try std.testing.expectEqualStrings("tbsp", result.recipe.ingredients[1].quantity.unit);
}

test "seam: cookware and timers are extracted and read naturally" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Lay them on a #baking sheet{} in the #oven. Bake for ~{25%minutes}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 2), result.recipe.cookware.len);
    try std.testing.expectEqualStrings("baking sheet", result.recipe.cookware[0].name);
    try std.testing.expectEqualStrings("oven", result.recipe.cookware[1].name);
    try std.testing.expectEqual(@as(usize, 1), result.recipe.timers.len);
    try std.testing.expectEqualStrings("25", result.recipe.timers[0].quantity.amount);
    try std.testing.expectEqualStrings("minutes", result.recipe.timers[0].quantity.unit);
    // The timer renders as its duration, not as markup.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "Bake for 25 minutes.") != null);
}

test "seam: a named timer keeps its name for notifications but still reads as a duration" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Boil @eggs{2} for ~eggs{3%minutes}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings("eggs", result.recipe.timers[0].name);
    try std.testing.expectEqualStrings("3", result.recipe.timers[0].quantity.amount);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "for 3 minutes.") != null);
}

test "seam: short-hand preparation is captured and shown in the ingredient list" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Mix @onion{1}(peeled and finely chopped) into paste.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings("peeled and finely chopped", result.recipe.ingredients[0].preparation);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "- onion — 1 (peeled and finely chopped)") != null);
    // The preparation is list-only; the step keeps reading as a sentence.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "1. Mix onion into paste.") != null);
}

test "seam: a recipe reference becomes a validated wiki link" {
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

test "seam: steps are numbered and sections restart the numbering" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown(
        "= Dough\n\nMix it.\n\n== Filling ==\n\nCombine it.\n\n",
        gpa,
    );
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings(
        "## Method\n\n### Dough\n\n1. Mix it.\n\n### Filling\n\n1. Combine it.\n\n",
        result.markdown,
    );
}

test "seam: a blank line separates steps" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("A step,\nthe same step.\n\nA different step.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // Oliver joins continuation lines with a single space (canonical), so a
    // wrapped step reads as one sentence instead of a hard-break artifact.
    try std.testing.expectEqualStrings(
        "## Method\n\n1. A step, the same step.\n\n2. A different step.\n\n",
        result.markdown,
    );
}

test "seam: a trailing backslash is a hard break in both languages" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Lay out the @rice paper{1}.\\\nTop with @avocado{1/2}.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // Cooklang's forced break and CommonMark's hard break are the same
    // character, so it survives instead of being escaped to a literal.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "rice paper.\\\n") != null);
}

test "seam: notes become blockquotes" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("> Don't burn the roux!\n\nStir it.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqualStrings(
        "## Method\n\n> Don't burn the roux\\!\n\n1. Stir it.\n\n",
        result.markdown,
    );
}

test "seam: line and block comments are removed" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Mash it -- or boil first.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // Oliver's step text keeps the space before the comment marker, matching
    // the old adapter's output; it renders identically in CommonMark.
    try std.testing.expectEqualStrings(
        "## Method\n\n1. Mash it \n\n",
        result.markdown,
    );
}

test "seam: block comments span lines and keep the step reading as one sentence" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown(
        "Cook for ~{9%minutes}, [- keep the cup -]\nthen drain.\n",
        gpa,
    );
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "1. Cook for 9 minutes, then drain.") != null);
}

test "seam: author text is escaped so it cannot forge document structure" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Add @salt{#1} and a `code` span and [[a link]] and <div>.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // `[[` is author text here (a recipe reference is the only `[[` the seam
    // emits itself); escaping keeps it inert in the rendered document.
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "\\[\\[a link\\]\\]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "&lt;div&gt;") != null);
}

test "seam: a line-initial colon cannot open a definition list" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown(": Not a definition.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "&#58; Not a definition.") != null);
}

test "seam: malformed structure degrades to literal text with a warning" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Add @flour{200%g to the bowl.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    // The unclosed `{` stays literal text (Oliver's documented degradation)
    // and a structured warning carries Oliver's stable code. The literal is
    // escaped like any other author text (`{` -> `\{`).
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings[0].message, "unclosed-braces") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "Add @flour\\{200%g to the bowl.") != null);
}

test "seam: an unterminated block comment warns and degrades" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Mix [- never closed\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings[0].message, "unclosed-block-comment") != null);
}

test "seam: an unclosed preparation warns and degrades" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Add @salt{1}(peeled and never closed.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings[0].message, "unclosed-preparation") != null);
}

test "seam: an invalid recipe reference is refused" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Pour over with @./sauces/pepper-oil|bad{1}.\n", gpa);
    try std.testing.expect(!result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostic.?.message, "not a valid page id") != null);
}

test "seam: a traversal recipe reference is refused" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Use @../sauces/x{1}.\n", gpa);
    try std.testing.expect(!result.isOk());
    defer freeResult(gpa, result);
}

test "seam: an empty timer is refused" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Rest for ~{}.\n", gpa);
    try std.testing.expect(!result.isOk());
    defer freeResult(gpa, result);
}

test "seam: control characters are refused" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("Add @salt\x01.\n", gpa);
    try std.testing.expect(!result.isOk());
    defer freeResult(gpa, result);
}

test "seam: an empty section name is refused" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("=\n\nMix it.\n", gpa);
    try std.testing.expect(!result.isOk());
    defer freeResult(gpa, result);
}

test "seam: frontmatter fence without a close warns and stays literal" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown("---\nservings: 4\n\nMix it.\n", gpa);
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings[0].message, "unclosed-frontmatter") != null);
}

test "seam: ingredients preserve authored order across sections" {
    const gpa = std.testing.allocator;
    const result = try toMarkdown(
        "= Base\n\nBeat @eggs{2}.\n\n= Sauce\n\nAdd @butter{30%g}.\n",
        gpa,
    );
    try std.testing.expect(result.isOk());
    defer freeResult(gpa, result);
    try std.testing.expectEqual(@as(usize, 2), result.recipe.ingredients.len);
    try std.testing.expectEqualStrings("eggs", result.recipe.ingredients[0].name);
    try std.testing.expectEqualStrings("butter", result.recipe.ingredients[1].name);
}
