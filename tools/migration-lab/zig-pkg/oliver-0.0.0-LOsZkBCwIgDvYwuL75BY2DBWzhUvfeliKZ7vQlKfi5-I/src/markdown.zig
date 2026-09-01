//! Markdown frontend.
//!
//! Implemented: paragraphs, ATX and Setext headings (§4.2/§4.3), thematic
//! breaks (§4.1), fenced code blocks (§4.5), block quotes (§5.1), list items
//! and lists (§5.2/§5.3), backslash escapes, hard and soft line breaks,
//! emphasis and strong emphasis, code spans (§6.1), raw HTML tags (§6.6),
//! inline links (§6.3), inline images (§6.4), and autolinks (§6.5). Behavior
//! is taken from the CommonMark specification (0.31.2) where the slice
//! implements it; divergences and chosen behaviors are documented in
//! docs/FEATURE-MATRIX.md, and the emphasis/strong algorithm is derived
//! in docs/INLINE-PARSING.md (leaf blocks: docs/LEAF-BLOCKS.md and
//! docs/FENCED-CODE.md; images: docs/IMAGES-PARSING.md;
//! autolinks: docs/AUTOLINKS.md).
//!
//! Code spans are discovered *before* the delimiter scan (a discovery pass
//! over the paragraph's raw content finds equal-length backtick-string
//! pairs); the scan then treats span content as opaque — no delimiters, no
//! escapes, no breaks inside — and the emit phase materializes a
//! `code_span` node with §6.1-normalized, arena-owned content. This is the
//! first delimiter-opacity rule (code-span markers are opaque to
//! delimiters; §6.1 "Code span backticks have higher precedence than any
//! other inline constructs").
//!
//! Inline links are discovered by a second pass between scan and match:
//! unescaped `[`/`]` become bracket items at scan time; the discovery pass
//! walks the item list with a bracket stack, and on each `]` tries to
//! parse an inline link `(...)` in the source that follows it. A valid
//! link splices the bracket range (plus the consumed `(...)` items) into a
//! single `link` item whose children are the link-text items; the
//! emphasis matcher then runs separately inside each link (the spec's
//! "process emphasis with the `[` opener as stack_bottom"), and brackets
//! that never form a link stay literal text. Because a link kills every
//! earlier `[` (links cannot contain links, §6.3), links are always
//! innermost-first and link text never contains another link. This is the
//! second delimiter-opacity rule (link brackets bind more tightly than
//! emphasis; `*[foo*](/uri)` is a link).
//!
//! Inline images ride the same discovery pass: `![` is its own opener on
//! the bracket stack, and an image description may contain links and
//! images — a formed link inactivates only earlier `[` openers, never
//! `![` (spec appendix; docs/IMAGES-PARSING.md §2). The description is
//! matched as a fresh inline scope and then flattened to the arena-owned
//! `alt` string (the spec's "only the plain string content of the image
//! description"), so `.image` is a leaf node like `code_span`. Images
//! reuse the link `(...)` parser and its DoS guards verbatim.
//!
//! Autolinks (§6.5) are recognized at scan time, like code spans: on an
//! unescaped `<` the scan tries a URI autolink (`<scheme:...>`, scheme
//! 2-32 chars) then an email autolink (`<user@host>`, the HTML5 regex),
//! and a match becomes a leaf `autolink` item whose content is opaque to
//! the delimiter stack and to link discovery (docs/AUTOLINKS.md §2). The
//! first-come-wins rule with code spans falls out of the left-to-right
//! walk: a backtick run before the `<` is skipped as a code span, a `<`
//! before the backticks consumes them as ordinary URI content.
//!
//! Raw HTML tags (§6.6) are discovered over the whole paragraph before the
//! line scan, because open/closing tags, comments, processing instructions,
//! declarations, and CDATA sections may span line endings. The discovered
//! tags merge with code spans into one first-come opaque-construct list;
//! recognized tags become leaf `raw_html` items whose source spans are
//! rendered verbatim (docs/RAW-HTML.md).
//!
//! The parser runs in two passes, matching the spec's precedence model:
//! block structure first, then inline structure. The block pass recognizes
//! paragraphs, ATX and Setext headings, thematic breaks, fenced code blocks,
//! block quotes, list items, and lists; unsupported leaf-block forms currently
//! fall back to paragraphs.
//!
//! The inline pass is discovery plus three phases (see
//! docs/INLINE-PARSING.md §8):
//!   scan  — one pass over each line's raw content span, producing a flat
//!           item list (text runs, delimiter runs, opaque constructs, line
//!           breaks). Flanking is computed against the raw span, so trailing
//!           whitespace and line boundaries classify runs exactly as the
//!           spec's "beginning and end of the line count as Unicode
//!           whitespace" requires; the leading/trailing whitespace trimming
//!           happens at emission.
//!   match — a delimiter stack processes the items left to right, matching
//!           openers to closers under rules 1-12 (§6.2), with an
//!           `openers_bottom` table so matching is amortized linear.
//!   emit  — the matched structure is materialized into document nodes;
//!           consumed delimiter bytes are covered by no node, leftover
//!           delimiters become literal text, escapes split text into
//!           adjacent nodes as before.
//!
//! Paragraph whitespace policy (deliberate; see docs/FEATURE-MATRIX.md):
//! - Leading spaces/tabs are skipped (not emitted) on every line.
//! - Trailing spaces/tabs are never emitted: a trailing run with two or more
//!   spaces produces a hard break, otherwise a soft break; the whole run is
//!   consumed. An unescaped trailing backslash also produces a hard break.
//! - ATX heading content is stripped of leading/trailing spaces/tabs before
//!   inline parsing (spec §4.2); a terminal backslash stays literal because
//!   hard breaks require a following inline-content line.

const std = @import("std");
const source = @import("source.zig");
const document = @import("document.zig");
const diagnostic = @import("diagnostic.zig");
const unicode = @import("unicode.zig");
const entities = @import("entities.zig");
const typography = @import("typography.zig");

pub const ParseError = error{OutOfMemory};

/// Tab stop width for block-structure indentation (§2.1): tabs behave as if
/// replaced by spaces with a tab stop of 4 characters when whitespace helps
/// define block structure. Content bytes are never expanded.
/// Markdown dialect extensions. All are **off by default**: the Markdown
/// frontend is byte-exact CommonMark 0.31.2 unless a consumer opts in, so
/// the CommonMark conformance corpus stays green. Each extension is a
/// documented, principled addition with its own contract doc and tests
/// (docs/MARKDOWN-EXTENSIONS.md).
pub const Options = struct {
    /// Pandoc-style footnotes: `[^label]` references plus `[^label]:`
    /// definitions, rendered as a footnotes section with back-references.
    footnotes: bool = false,
    /// Pandoc-style definition lists: a term paragraph immediately followed
    /// by `:` (or `~`) definition lines, rendered as `<dl><dt><dd>`.
    definition_lists: bool = false,
    /// Kramdown/MultiMarkdown-style heading attribute lists: a trailing
    /// `{#id .class}` on ATX and Setext headings, consumed as the heading's
    /// explicit `id`/`class`.
    heading_attributes: bool = false,
    /// GFM strikethrough: a run of exactly two tildes (`~~text~~`) renders
    /// as `<del>text</del>`; runs of one or three-plus tildes stay literal.
    /// Flanking follows the CommonMark emphasis rules (GFM spec §6.5
    /// "Strikethrough (extension)").
    strikethrough: bool = false,
    /// Obsidian-style wikilinks: `[[Page Name]]` and
    /// `[[Page Name|Custom Label]]` parse into a `.wikilink` inline node
    /// (resolved at render time by a resolver policy, docs/WIKILINKS.md).
    /// Recognized ahead of link brackets; malformed shapes (unterminated,
    /// empty/whitespace targets, empty labels, `[[a|b|c]]`, `[[` inside
    /// the target) stay literal. Off by default so the CommonMark corpus
    /// stays byte-exact.
    wikilinks: bool = false,
    /// Obsidian-style callouts: a `[!type]` immediately after the quote
    /// marker on a blockquote's first content line (`> [!note] Title`)
    /// turns the blockquote into a semantic callout (docs/CALLOUTS.md):
    /// the marker is consumed, the remainder of the line is the
    /// inline-parsed title, and the rest of the quote is the body. The
    /// type is ASCII letters/digits/`-`, case-insensitive, unknown types
    /// render as a `callout-<type>` box. Malformed shapes (empty or
    /// space-containing types, a missing `]`, no separator, mid-line or
    /// non-first-line markers, leading whitespace after the quote marker)
    /// stay literal. Off by default so the CommonMark corpus stays
    /// byte-exact.
    callouts: bool = false,
    /// Smart typography: the Textile character-replacement pass (curly
    /// quotes by direction, em/en dashes, ellipsis, the dimension sign,
    /// the parenthesized symbols) applied to plain text in every inline
    /// scope — one shared implementation with Textile
    /// (docs/SMARTY.md). The `{...}` character-macro table stays
    /// Textile-only; escaped `\"`/`\'` render the straight character;
    /// code, autolinks, raw HTML, and link/image payloads are exempt.
    /// Off by default so the CommonMark corpus stays byte-exact.
    smartypants: bool = false,
};

const tab_stop: u32 = 4;

/// A line view during the block pass: the remaining `line` plus the
/// tab-expanded column of its first byte. When a container prefix consumes
/// only part of a tab, the tab byte stays as the view's first byte and
/// `col` points into the middle of it, so later whitespace arithmetic
/// measures from the same absolute tab stop (the reference implementation's
/// `partially_consumed_tab` model).
const View = struct {
    line: source.Line,
    col: u32,

    fn init(line: source.Line) View {
        return .{ .line = line, .col = 0 };
    }

    /// The view starting at byte index `i` of this view's text, at the
    /// tab-expanded column `col`.
    fn after(self: View, i: usize, col: u32) View {
        return .{
            .line = .{
                .text = self.line.text[i..],
                .start = self.line.start + i,
                .content_end = self.line.content_end,
                .end = self.line.end,
            },
            .col = col,
        };
    }
};

/// Columns of leading whitespace in a view, with tabs advancing to the next
/// multiple of `tab_stop` measured from the view's column (§2.1). This is
/// the indentation relevant to block structure, relative to the current
/// container content.
fn viewIndent(view: View) u32 {
    var col = view.col;
    var cols: u32 = 0;
    for (view.line.text) |b| {
        switch (b) {
            ' ' => {
                col += 1;
                cols += 1;
            },
            '\t' => {
                const adv = tab_stop - (col % tab_stop);
                col += adv;
                cols += adv;
            },
            else => break,
        }
    }
    return cols;
}

/// Advances a view by `n` columns of leading whitespace. A tab that
/// straddles the boundary keeps its byte as the new view's first byte with
/// `col` mid-tab. Returns null when the leading whitespace is shorter than
/// `n` columns.
fn advanceColumns(view: View, n: u32) ?View {
    var col = view.col;
    var i: usize = 0;
    var remaining = n;
    const t = view.line.text;
    while (remaining > 0) {
        if (i >= t.len) return null;
        switch (t[i]) {
            ' ' => {
                col += 1;
                i += 1;
                remaining -= 1;
            },
            '\t' => {
                const adv = tab_stop - (col % tab_stop);
                if (adv <= remaining) {
                    col += adv;
                    i += 1;
                    remaining -= adv;
                } else {
                    col += remaining;
                    remaining = 0;
                }
            },
            else => return null,
        }
    }
    return view.after(i, col);
}

/// Bounded leading-indent walk: the byte index and columns consumed up to
/// `limit` columns of leading whitespace, or null when the indentation
/// exceeds the limit. Any leading tab reaches four columns or more from any
/// position except mid-tab, so a walk that accepts tabs naturally bounds
/// the indent.
const IndentWalk = struct { i: usize, cols: u32 };

fn skipIndent(view: View, limit: u32) ?IndentWalk {
    var col = view.col;
    var cols: u32 = 0;
    var i: usize = 0;
    const t = view.line.text;
    while (i < t.len) {
        switch (t[i]) {
            ' ' => {
                col += 1;
                cols += 1;
                i += 1;
            },
            '\t' => {
                const adv = tab_stop - (col % tab_stop);
                cols += adv;
                if (cols > limit) return null;
                col += adv;
                i += 1;
            },
            else => break,
        }
        if (cols > limit) return null;
    }
    return .{ .i = i, .cols = cols };
}

/// Appends one literal code line to `out`: strips `strip` columns of
/// leading whitespace (a tab straddling the boundary leaves spaces for its
/// remaining columns), then the remaining bytes and a newline. Shared by
/// indented and fenced code content.
fn appendCodeContentLine(
    doc: *document.Document,
    out: *std.ArrayList(u8),
    view: View,
    strip: u32,
) ParseError!void {
    var col = view.col;
    var i: usize = 0;
    var remaining = strip;
    const t = view.line.text;
    while (remaining > 0 and i < t.len) {
        switch (t[i]) {
            ' ' => {
                col += 1;
                i += 1;
                remaining -= 1;
            },
            '\t' => {
                const adv = tab_stop - (col % tab_stop);
                if (adv <= remaining) {
                    col += adv;
                    i += 1;
                    remaining -= adv;
                } else {
                    try out.appendNTimes(doc.allocator(), ' ', adv - remaining);
                    col += remaining;
                    i += 1;
                    remaining = 0;
                }
            },
            else => break,
        }
    }
    try out.appendSlice(doc.allocator(), t[i..]);
    try out.append(doc.allocator(), '\n');
}

/// Drops trailing blank lines (lines of only spaces/tabs) from indented-code
/// content, then the caller re-appends the single final newline: an
/// indented code block ends at the first line with fewer than four spaces of
/// indentation, and blank lines beyond its last content line are not part of
/// it (§4.4).
fn removeTrailingBlankLines(out: *std.ArrayList(u8)) void {
    const items = out.items;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const b = items[i];
        if (b != ' ' and b != '\t' and b != '\n') break;
    }
    var j = i;
    while (j < items.len) : (j += 1) {
        if (items[j] == '\n') {
            out.shrinkRetainingCapacity(j);
            return;
        }
    }
    out.clearRetainingCapacity();
}

/// Parses `doc.src` as Markdown, appending block nodes under `doc.root`.
/// The caller (`oliver.parse`) guarantees
/// `doc.src.bytes.len <= source.max_input_len`, so all offsets fit in `u32`.
pub fn parse(doc: *document.Document, diags: *std.ArrayList(diagnostic.Diagnostic), options: Options) ParseError!void {
    _ = diags;

    // Two-phase parse (spec appendix "A parsing strategy"): phase 1 builds
    // the block structure and collects link reference definitions (§4.7)
    // into `defs`; inline parsing is deferred to phase 2, because a
    // reference link may precede the definition it uses. `pending` records
    // each block's raw content for the second pass.
    //
    // Phase 1 keeps a stack of open *container* blocks (block quotes, lists,
    // list items) plus one open leaf (a paragraph). Each line is matched
    // against the containers top-down, consuming markers and indentation;
    // unmatched containers stay open only for a lazy paragraph continuation,
    // and are otherwise closed (see docs/BLOCKS-PARSING.md §5). The document
    // root is implicit below the stack, so `leafParent` is the deepest
    // container or `doc.root`.
    var defs = Definitions.init(doc.allocator());
    defer defs.deinit();
    var pending = std.ArrayList(PendingInline).empty;
    defer pending.deinit(doc.allocator());
    var containers = std.ArrayList(ContainerState).empty;
    defer containers.deinit(doc.allocator());
    var paragraph: ?Paragraph = null;
    var fenced: ?FencedCode = null;
    var indented: ?IndentedCode = null;
    var html: ?HtmlBlock = null;
    var table: ?TableBlock = null;
    // Markdown definition-list state (extension): the open `.definition_list`
    // node and its current `.definition_body` node, null when inactive.
    var def_list: ?*document.Node = null;
    var def_body: ?*document.Node = null;

    var lines = source.Lines.init(doc.src.bytes);
    while (lines.next()) |line| {
        // A. Match open containers top-down, consuming one marker each. A
        // block quote consumes `> `; a list item consumes its content
        // indentation; a list consumes nothing (its fate is decided by its
        // item and by whether a new same-type item starts).
        var view = View.init(line);
        var matched: usize = 0;
        while (matched < containers.items.len) {
            const c = &containers.items[matched];
            switch (c.node.tag) {
                .block_quote => {
                    const stripped = tryStripBlockQuoteMarker(view) orelse break;
                    view = stripped;
                },
                .list => {
                    // With no item on the stack below it the list is dead
                    // (its blank-start item was already popped).
                    if (matched + 1 >= containers.items.len) break;
                },
                .list_item => {
                    if (c.inert) break;
                    if (isBlank(view.line.text)) {
                        // Blank lines match list items without requiring the
                        // full content indentation. Still consume as much of
                        // that structural indentation as is present: an open
                        // leaf observes excess spaces as literal content, but
                        // never the list item's own prefix.
                        if (c.initial_blank_pending) c.inert = true;
                        const indent = viewIndent(view);
                        view = advanceColumns(view, @min(indent, c.content_indent)) orelse unreachable;
                    } else {
                        const indent = viewIndent(view);
                        if (indent < c.content_indent) break;
                        view = advanceColumns(view, c.content_indent) orelse unreachable;
                        // Rule 3 limits only the blank prefix before the
                        // item's first block. Once nonblank content matches,
                        // later blank lines are ordinary item content.
                        c.initial_blank_pending = false;
                    }
                },
                else => unreachable,
            }
            matched += 1;
        }

        // An open fenced-code leaf owns every line while its containing
        // containers still match. Its contents are literal: no blank-line,
        // lazy-continuation, block-start, or inline rule runs here. If a
        // containing block ends, finalize without backtracking and reprocess
        // this same physical line normally outside the container.
        if (fenced) |*active| {
            if (matched == active.container_depth) {
                if (isFenceClose(view, active.marker, active.fence_len)) {
                    active.node.span.end = @intCast(view.line.content_end);
                    finishFencedCode(&fenced);
                    extendContainerSpans(&containers, view.line);
                    continue;
                }
                try appendFencedContentLine(doc, active, view);
                active.node.span.end = @intCast(view.line.content_end);
                extendContainerSpans(&containers, view.line);
                continue;
            }
            std.debug.assert(matched < active.container_depth);
            finishFencedCode(&fenced);
        }

        // An open indented-code leaf owns every line while its containing
        // containers still match: blank lines are chunk separators (§4.4),
        // and a nonblank line continues the block only while it is indented
        // at least four columns. Any other line ends the block; trailing
        // blank lines are dropped from the content, and the line is
        // reprocessed normally.
        if (indented) |*active| {
            if (matched == active.container_depth) {
                if (isBlank(view.line.text)) {
                    try appendCodeContentLine(doc, &active.content, view, 4);
                    active.node.span.end = @intCast(view.line.content_end);
                    extendContainerSpans(&containers, view.line);
                    continue;
                }
                if (viewIndent(view) >= 4) {
                    try appendCodeContentLine(doc, &active.content, view, 4);
                    active.node.span.end = @intCast(view.line.content_end);
                    extendContainerSpans(&containers, view.line);
                    continue;
                }
                try finishIndentedCode(doc, &indented);
            } else {
                std.debug.assert(matched < active.container_depth);
                try finishIndentedCode(doc, &indented);
            }
        }

        // An open HTML block (§4.6) owns every line while its containing
        // containers still match. Types 1-5 end at the first line containing
        // their terminator (blank lines are content — a `<script>` block may
        // contain blank lines); types 6/7 end at a blank line. A container
        // whose marker is absent ends the block either way. Content is the
        // remainder verbatim, so the line is consumed wholesale: no
        // blank-line, lazy-continuation, block-start, or inline rule runs
        // here.
        if (html) |*active| {
            if (matched == active.container_depth) {
                if (active.block_type <= 5) {
                    try appendHtmlBlockLine(doc, &active.content, view);
                    active.node.span.end = @intCast(view.line.content_end);
                    if (htmlBlockEnded(active.block_type, view.line.text)) {
                        finishHtmlBlock(&html);
                    }
                    extendContainerSpans(&containers, view.line);
                    continue;
                }
                if (!isBlank(view.line.text)) {
                    try appendHtmlBlockLine(doc, &active.content, view);
                    active.node.span.end = @intCast(view.line.content_end);
                    extendContainerSpans(&containers, view.line);
                    continue;
                }
                finishHtmlBlock(&html);
            } else {
                std.debug.assert(matched < active.container_depth);
                finishHtmlBlock(&html);
            }
        }

        // The same physical line can be re-examined at many nested list
        // depths. Summarize its thematic-break suffixes once so precedence
        // checks stay O(1) per consumed container marker. Literal fenced-code
        // content bypasses this work above.
        const thematic_facts = ThematicLineFacts.init(line);

        // An open table leaf (GFM §4.10 extension) owns every line while
        // its containing containers still match. A blank line or the start
        // of another block-level structure ends the table (the line is then
        // reprocessed normally); any other line is a body row — including a
        // pipe-less line, which becomes a single-cell row (spec example:
        // `bar` after the rows is one row, `bar` after a blank line is a
        // paragraph).
        if (table) |*active| {
            if (matched == active.container_depth) {
                if (isBlank(view.line.text) or !isParagraphContinuationText(doc, view, &thematic_facts)) {
                    finishTable(&table);
                } else {
                    const cells = try splitRowCells(doc, view.line.contentSpan());
                    try appendTableRow(doc, active.node, view.line.contentSpan(), cells, false, &pending);
                    active.node.span.end = @intCast(view.line.content_end);
                    extendContainerSpans(&containers, view.line);
                    continue;
                }
            } else {
                std.debug.assert(matched < active.container_depth);
                finishTable(&table);
            }
        }

        // B. Blank line: close the leaf and any container whose marker was
        // absent. Blank lines keep block quotes (marker-blank) and list
        // items open; a blank line may make a list loose, but the decision
        // is deferred until the next line shows whether the blank separated
        // blocks inside an item or two items (§5.3).
        if (isBlank(view.line.text)) {
            // A definition body's paragraph closes into its `<dd>`, not the
            // document root.
            const close_parent = if (def_body != null) def_body.? else leafParent(doc, &containers);
            try closeParagraph(doc, &paragraph, close_parent, &defs, &pending, options);
            def_list = null;
            def_body = null;
            noteListBlankLines(&containers, matched);
            containers.shrinkRetainingCapacity(matched);
            // A blank line with only a dead item on the stack (an inert
            // blank-start item failed to match) closes its list too.
            if (containers.items.len > 0 and containers.items[containers.items.len - 1].node.tag == .list) {
                containers.shrinkRetainingCapacity(containers.items.len - 1);
            }
            extendContainerSpans(&containers, view.line);
            continue;
        }

        // B2. Markdown definition lists (extension): a `:`/`~` definition
        // marker directly after a term paragraph, or a continuation line
        // (1–3 columns indented) of an open definition body. Only runs when
        // every open container matched (a def marker that fails its
        // container is a lazy paragraph continuation, decided in C). A
        // marker line closes the previous body (if any), or turns the open
        // paragraph into a term under the (possibly new) `<dl>`; an
        // unindented or 4+-column line ends the open body while the list
        // stays open for a following term.
        if (options.definition_lists and matched == containers.items.len and
            (paragraph != null or def_list != null))
        {
            if (tryDefListMarker(view)) |rest| {
                if (paragraph == null and def_body == null) {
                    // A stale open list with no pending term (a block
                    // interrupted it): reset and fall through, so the
                    // marker stays ordinary text.
                    def_list = null;
                    def_body = null;
                } else if (def_body != null) {
                    // The open paragraph (if any) belongs to the previous
                    // definition; close it there.
                    try closeParagraph(doc, &paragraph, def_body.?, &defs, &pending, options);
                } else {
                    // The open paragraph is a term.
                    if (def_list == null) {
                        const list_node = try doc.createNode(.definition_list, .{
                            .start = paragraph.?.start,
                            .end = @intCast(view.line.content_end),
                        }, .none);
                        try doc.appendChild(leafParent(doc, &containers), list_node);
                        def_list = list_node;
                    }
                    try closeParagraphAs(doc, &paragraph, def_list.?, &defs, &pending, options, .definition_term);
                }
                const body = try doc.createNode(.definition_body, .{
                    .start = @intCast(view.line.start),
                    .end = @intCast(view.line.content_end),
                }, .none);
                try doc.appendChild(def_list.?, body);
                def_body = body;
                try appendParagraphLine(doc, &paragraph, rest);
                extendContainerSpans(&containers, view.line);
                continue;
            }
            if (def_body != null) {
                // A non-marker line: continuation of the definition body's
                // paragraph (1–3 columns), or the end of the body.
                const indent = viewIndent(view);
                if (indent >= 1 and indent < 4 and paragraph != null) {
                    try appendParagraphLine(doc, &paragraph, view);
                    extendContainerSpans(&containers, view.line);
                    continue;
                }
                try closeParagraph(doc, &paragraph, def_body.?, &defs, &pending, options);
                def_body = null;
            }
        }

        // C. Lazy continuation (§5.1 rule 2, §5.2 rule 5): a line that
        // fails a container's condition can still continue the paragraph
        // inside it, if the remainder is paragraph continuation text.
        // Otherwise the unmatched containers close and the line is
        // reprocessed as a fresh start. A list whose item failed without a
        // replacement item closes too.
        if (matched < containers.items.len) {
            const list_sibling = startsListSibling(&containers, matched, view, &thematic_facts);
            resolveListBlankPending(&containers, matched, view, &thematic_facts);
            if (paragraph != null and !list_sibling and isParagraphContinuationText(doc, view, &thematic_facts)) {
                try appendParagraphLine(doc, &paragraph, view);
                extendContainerSpans(&containers, view.line);
                continue;
            }
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending, options);
            def_list = null;
            def_body = null;
            containers.shrinkRetainingCapacity(matched);
            if (containers.items.len > 0 and containers.items[containers.items.len - 1].node.tag == .list) {
                const top_list = containers.items[containers.items.len - 1].node;
                const m = tryListMarkerAfterLeafPrecedence(view, &thematic_facts);
                if (m == null or !sameListType(top_list, m.?)) {
                    containers.shrinkRetainingCapacity(containers.items.len - 1);
                }
            }
        } else {
            resolveListBlankPending(&containers, matched, view, &thematic_facts);
        }

        // D. New block starts on the remainder. Block quotes and list
        // markers may nest (each consumes its marker and the remainder is
        // re-examined). Thematic breaks take precedence over list markers;
        // a Setext underline transforms an eligible open paragraph before a
        // one- or two-dash line can become an empty list item (§4.1/§4.3).
        // A list item interrupts an open paragraph only when it can (§5.2
        // rule 1 exceptions); otherwise the line is paragraph text.
        while (true) {
            if (tryStripBlockQuoteMarker(view)) |stripped| {
                try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending, options);
                def_list = null;
                def_body = null;
                const node = try doc.createNode(.block_quote, stripped.line.contentSpan(), .{ .block_quote = .{} });
                try doc.appendChild(leafParent(doc, &containers), node);
                try containers.append(doc.allocator(), .{ .node = node });
                view = stripped;
                // Callout (extension): the first content line of a
                // blockquote may open a callout. The `[!type] ` marker and
                // the inline title consume the whole line, so the empty
                // remainder is a blank line inside the quote (no body
                // content on this line; docs/CALLOUTS.md §1–§2).
                if (options.callouts) _ = try tryTakeCallout(doc, node, &view, &pending);
                continue;
            }
            if (isThematicBreak(view, &thematic_facts) or
                (trySetextUnderline(view) != null and setextContentIndex(doc, paragraph) != null))
            {
                break;
            }
            if (tryListMarker(view)) |m| {
                if (paragraph != null and !m.can_interrupt) break;
                try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending, options);
                def_list = null;
                def_body = null;
                // Reuse an open same-type list, or close a different-type
                // list, or open a new list under the current parent.
                var list_node: *document.Node = undefined;
                if (containers.items.len > 0 and containers.items[containers.items.len - 1].node.tag == .list) {
                    const top_state = &containers.items[containers.items.len - 1];
                    const top = top_state.node;
                    if (sameListType(top, m)) {
                        list_node = top;
                    } else {
                        containers.shrinkRetainingCapacity(containers.items.len - 1);
                        list_node = try doc.createNode(.list, m.rest.line.contentSpan(), .{ .list = m.listData() });
                        try doc.appendChild(leafParent(doc, &containers), list_node);
                        try containers.append(doc.allocator(), .{ .node = list_node });
                    }
                } else {
                    list_node = try doc.createNode(.list, m.rest.line.contentSpan(), .{ .list = m.listData() });
                    try doc.appendChild(leafParent(doc, &containers), list_node);
                    try containers.append(doc.allocator(), .{ .node = list_node });
                }
                const item = try doc.createNode(.list_item, m.rest.line.contentSpan(), .none);
                try doc.appendChild(list_node, item);
                try containers.append(doc.allocator(), .{
                    .node = item,
                    .content_indent = m.content_indent,
                    .initial_blank_pending = m.blank_start,
                });
                view = m.rest;
                continue;
            }
            break;
        }
        // A marker-only line (`>` alone, or a line whose markers are all
        // consumed, or a blank-start list item) is a blank line inside the
        // container, not an empty paragraph.
        if (isBlank(view.line.text)) {
            // A definition body's paragraph closes into its `<dd>`, not the
            // document root.
            const close_parent = if (def_body != null) def_body.? else leafParent(doc, &containers);
            try closeParagraph(doc, &paragraph, close_parent, &defs, &pending, options);
            def_list = null;
            def_body = null;
            extendContainerSpans(&containers, view.line);
            continue;
        }
        if (tryFenceOpen(view)) |opening| {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending, options);
            def_list = null;
            def_body = null;
            const info = if (opening.info.isEmpty())
                null
            else
                try resolveEscapes(doc, opening.info);
            const node = try doc.createNode(.code_block, view.line.contentSpan(), .{
                .code_block = .{ .content = &.{}, .info = info },
            });
            try doc.appendChild(leafParent(doc, &containers), node);
            fenced = .{
                .node = node,
                .marker = opening.marker,
                .fence_len = opening.fence_len,
                .indent = opening.indent,
                .container_depth = containers.items.len,
            };
            extendContainerSpans(&containers, view.line);
            continue;
        }
        if (trySetextUnderline(view)) |underline| {
            if (try emitSetextHeading(
                doc,
                &paragraph,
                view,
                underline,
                leafParent(doc, &containers),
                &defs,
                &pending,
                options,
            )) {
                def_list = null;
                def_body = null;
                extendContainerSpans(&containers, view.line);
                continue;
            }
        }
        if (isThematicBreak(view, &thematic_facts)) {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending, options);
            def_list = null;
            def_body = null;
            // A failed list item can leave its list as the deepest matched
            // container. A thematic break is not a sibling item: it belongs
            // beside that list, never directly under the `.list` node.
            if (containers.items.len > 0 and containers.items[containers.items.len - 1].node.tag == .list) {
                containers.shrinkRetainingCapacity(containers.items.len - 1);
            }
            const node = try doc.createNode(.thematic_break, view.line.contentSpan(), .none);
            try doc.appendChild(leafParent(doc, &containers), node);
            extendContainerSpans(&containers, view.line);
            continue;
        }
        if (tryAtxHeading(view)) |heading| {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending, options);
            def_list = null;
            def_body = null;
            try emitHeading(doc, view, heading, leafParent(doc, &containers), &pending, options);
            extendContainerSpans(&containers, view.line);
            continue;
        }
        // HTML blocks (§4.6), all seven types. Types 1-6 may interrupt a
        // paragraph; type 7 may not, so it is only tried when no paragraph
        // is open. The node is appended at open (container order fixed) and
        // content accumulates verbatim; types 1-5 end at their terminator
        // (which may be on the opening line itself — then the block is just
        // that line), types 6/7 at a blank line or the end of their
        // container.
        if (tryHtmlBlockStart(doc, view, paragraph == null)) |block_type| {
            try closeParagraph(doc, &paragraph, leafParent(doc, &containers), &defs, &pending, options);
            def_list = null;
            def_body = null;
            const node = try doc.createNode(.html_block, view.line.contentSpan(), .{
                .html_block = &.{},
            });
            try doc.appendChild(leafParent(doc, &containers), node);
            html = .{
                .node = node,
                .container_depth = containers.items.len,
                .block_type = block_type,
            };
            try appendHtmlBlockLine(doc, &html.?.content, view);
            node.span.end = @intCast(view.line.content_end);
            if (block_type <= 5 and htmlBlockEnded(block_type, view.line.text)) {
                finishHtmlBlock(&html);
            }
            extendContainerSpans(&containers, view.line);
            continue;
        }
        // Indented code blocks (§4.4): a chunk needs four or more columns of
        // indentation and cannot interrupt a paragraph, so this is the last
        // block start, guarded by no open paragraph. The node is appended at
        // open so container order is fixed; content accumulates incrementally
        // and trailing blank lines are dropped at close.
        if (paragraph == null and viewIndent(view) >= 4) {
            def_list = null;
            def_body = null;
            const node = try doc.createNode(.code_block, view.line.contentSpan(), .{
                .code_block = .{ .content = &.{}, .info = null },
            });
            try doc.appendChild(leafParent(doc, &containers), node);
            indented = .{
                .node = node,
                .container_depth = containers.items.len,
            };
            try appendCodeContentLine(doc, &indented.?.content, view, 4);
            node.span.end = @intCast(view.line.content_end);
            extendContainerSpans(&containers, view.line);
            continue;
        }

        // E. Paragraph text.
        // GFM tables extension (§4.10): a fresh single-line paragraph whose
        // line parses as a table header row becomes a table when the
        // current line is a matching delimiter row. Otherwise the line is
        // ordinary paragraph text.
        if (try tryEmitTable(doc, &paragraph, view, leafParent(doc, &containers), containers.items.len, &table, &pending)) {
            def_list = null;
            def_body = null;
            extendContainerSpans(&containers, view.line);
            continue;
        }
        try appendParagraphLine(doc, &paragraph, view);
        extendContainerSpans(&containers, view.line);
    }
    finishFencedCode(&fenced);
    try finishIndentedCode(doc, &indented);
    finishHtmlBlock(&html);
    finishTable(&table);
    // A trailing definition body's paragraph closes into its `<dd>`.
    const close_parent = if (def_body != null) def_body.? else leafParent(doc, &containers);
    try closeParagraph(doc, &paragraph, close_parent, &defs, &pending, options);

    // Phase 2: inline pass, with the full definitions map available.
    for (pending.items) |job| {
        switch (job) {
            .paragraph => |pp| try parseParagraphInlines(doc, pp.node, pp.lines, &defs, options),
            .heading => |hh| try parseHeadingInlines(doc, hh.node, hh.span, &defs, options),
            .setext_heading => |hh| try parseSetextHeadingInlines(doc, hh.node, hh.lines, &defs, options),
            .table_cell => |tc| try parseTableCellInlines(doc, tc.node, tc.span, &defs, options),
            .callout_title => |ct| try parseCalloutTitleInlines(doc, ct.node, ct.span, &defs, options),
        }
    }
}

/// Per-container state on the phase-1 stack.
const ContainerState = struct {
    node: *document.Node,
    /// For `.list_item`: the content indentation (marker indentation + W +
    /// N, §5.2 rules 1–3), in spaces — how far a continuation line must be
    /// indented to stay in the item.
    content_indent: u32 = 0,
    /// For `.list_item`: no nonblank block has followed a marker-only start
    /// yet. A second blank while this is true makes the item inert (§5.2
    /// rule 3); the flag clears when the first nonblank content line matches.
    initial_blank_pending: bool = false,
    /// For `.list_item`: dead after its second blank line ("A list item can
    /// begin with at most one blank line"); matches nothing.
    inert: bool = false,
    /// For `.list`: a blank line was seen while this list was open. The
    /// loose decision is deferred (docs/BLOCKS-PARSING.md §4) until the next
    /// line shows whether it separates direct blocks/items in this list.
    blank_pending: bool = false,
};

/// The node under which a new leaf or container is created: the deepest
/// open container, or the document root when the stack is empty.
fn leafParent(doc: *document.Document, containers: *const std.ArrayList(ContainerState)) *document.Node {
    if (containers.items.len == 0) return doc.root;
    return containers.items[containers.items.len - 1].node;
}

/// Extends every open container's span end to cover the current line, so a
/// block quote's or list item's span is the union of its (marker-stripped)
/// content lines. `line.content_end` is the full line's content end;
/// stripping only moves the start, so this is correct for matched, lazy,
/// and blank-marker lines alike.
fn extendContainerSpans(containers: *const std.ArrayList(ContainerState), line: source.Line) void {
    const end: u32 = @intCast(line.content_end);
    for (containers.items) |c| {
        if (c.node.span.end < end) c.node.span.end = end;
    }
}

/// Strips one block quote marker (§5.1): up to three columns of leading
/// indentation, `>`, then one following column of indentation. The
/// following space may be a tab; a tab that is only partially consumed
/// keeps its byte as the new view's first byte (see `View`).
fn tryStripBlockQuoteMarker(view: View) ?View {
    const t = view.line.text;
    const skipped = skipIndent(view, 3) orelse return null;
    var i = skipped.i;
    var col = view.col + skipped.cols;
    if (i >= t.len or t[i] != '>') return null;
    i += 1;
    col += 1;
    if (i < t.len and (t[i] == ' ' or t[i] == '\t')) {
        if (t[i] == ' ') {
            i += 1;
            col += 1;
        } else {
            const adv = tab_stop - (col % tab_stop);
            if (adv > 1) {
                col += 1; // partial: the tab byte remains as the view start
            } else {
                i += 1;
                col += 1;
            }
        }
    }
    return view.after(i, col);
}

/// Callout recognition on a blockquote's first content line (extension,
/// docs/CALLOUTS.md §1–§3): if `view` starts with a `[!type]` marker
/// immediately after the quote marker (no leading whitespace), consumes
/// the marker and the inline title, sets the blockquote's callout
/// payload, and points `view` past the whole line. Returns false when the
/// line is not a callout shape — the bytes stay literal. The type is a
/// non-empty run of ASCII letters/digits/`-`, case-insensitive; after the
/// `]` a space/tab (or end of line) is required; the title is the trimmed
/// remainder.
fn tryTakeCallout(
    doc: *document.Document,
    node: *document.Node,
    view: *View,
    pending: *std.ArrayList(PendingInline),
) ParseError!bool {
    const t = view.line.text;
    if (t.len < 3 or t[0] != '[' or t[1] != '!') return false;
    var close: usize = 2;
    while (close < t.len and t[close] != ']') : (close += 1) {
        const c = t[close];
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-')) return false;
    }
    if (close >= t.len or close == 2) return false; // `[!note` (no `]`) or `[!]`
    if (close + 1 < t.len and t[close + 1] != ' ' and t[close + 1] != '\t') return false; // `[!note]x`

    // Normalized lowercase type: an arena-owned copy.
    const raw_type = t[2..close];
    const ctype = try doc.allocator().dupe(u8, raw_type);
    for (ctype) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
    }
    node.data.block_quote.callout_type = ctype;

    // The title: the trimmed remainder of the line after `]` and the
    // separator. Only whitespace (or end of line) means no title.
    var s: usize = close + 1;
    while (s < t.len and (t[s] == ' ' or t[s] == '\t')) : (s += 1) {}
    var e = t.len;
    while (e > s and (t[e - 1] == ' ' or t[e - 1] == '\t')) : (e -= 1) {}
    if (s < e) {
        node.data.block_quote.callout_title = t[s..e];
        try pending.append(doc.allocator(), .{
            .callout_title = .{
                .node = node,
                .span = .{ .start = @intCast(view.line.start + s), .end = @intCast(view.line.start + e) },
            },
        });
    }

    // Consume the whole line: the empty remainder is a blank line inside
    // the quote, so no body content starts on the callout's first line.
    view.* = view.after(t.len, view.col + @as(u32, @intCast(t.len)));
    return true;
}

/// Recognizes a definition-list marker line (extension): `:` or `~`
/// preceded by at most three columns of indentation and followed by a
/// space/tab. Returns the view after the marker and its single separator
/// (further whitespace stays as content; the inline pass trims it).
fn tryDefListMarker(view: View) ?View {
    const skipped = skipIndent(view, 3) orelse return null;
    const t = view.line.text;
    var i = skipped.i;
    if (i >= t.len) return null;
    if (t[i] != ':' and t[i] != '~') return null;
    i += 1;
    if (i >= t.len or (t[i] != ' ' and t[i] != '\t')) return null;
    i += 1;
    return view.after(i, skipped.cols + 2);
}

/// A list marker recognized on a line (§5.2): a bullet character (`-`,
/// `+`, `*`) or 1–9 digits followed by `.` or `)`, optionally preceded by
/// up to three spaces.
const ListMarker = struct {
    const Kind = enum { bullet, ordered };

    kind: Kind,
    /// Bullet marker character, for same-type merging (§5.3).
    bullet: u8 = 0,
    /// Ordered delimiter (`.` or `)`), for same-type merging.
    delimiter: u8 = 0,
    /// Ordered start number (the marker's number; 1 for bullets).
    start: u32 = 1,
    /// Marker width W (1 for bullets; digits + 1 for ordered).
    width: u32,
    /// Content indentation of the item being opened: marker indentation
    /// plus W plus N (§5.2 rules 1–3; N=1 for blank-start and
    /// indented-code-first items).
    content_indent: u32,
    /// The item's first line begins with a blank line (rule 3).
    blank_start: bool,
    /// The content view after the marker and its indentation.
    rest: View,
    /// Whether the item may interrupt an open paragraph: not when it
    /// begins with a blank line, and for ordered items not when the start
    /// number is not 1 (§5.2 rule 1 exceptions).
    can_interrupt: bool,

    fn listData(self: ListMarker) document.List {
        return switch (self.kind) {
            .bullet => .{ .kind = .bullet, .bullet = self.bullet },
            .ordered => .{ .kind = .ordered, .delimiter = self.delimiter, .start = self.start },
        };
    }
};

/// Recognizes a list marker at the start of a view (§5.2). The marker may
/// be preceded by up to three columns of indentation (measured in the
/// current view — a quote's content — so nested lists compose); tabs are
/// expanded to tab stops. The content indentation is the marker's own
/// indentation plus W plus N (rules 1–3): the spec's "let the width and
/// indentation of the list marker determine the indentation necessary for
/// blocks to fall under the list item" (docs/BLOCKS-PARSING.md §3).
///
/// Whitespace after the marker is counted in columns: 1–4 columns is rule 1
/// (N = the whitespace columns, all consumed); 5+ columns or end of line
/// means the item begins with an indented code block or a blank line
/// (rules 2/3), the content indentation is W+1, and the content starts one
/// column past the marker with the remaining whitespace preserved.
fn tryListMarker(view: View) ?ListMarker {
    const t = view.line.text;
    const skipped = skipIndent(view, 3) orelse return null;
    var i = skipped.i;
    var col = view.col + skipped.cols;
    const marker_indent = skipped.cols;
    if (i >= t.len) return null;

    var kind: ListMarker.Kind = undefined;
    var bullet: u8 = 0;
    var delimiter: u8 = 0;
    var start: u32 = 1;
    var width: u32 = 0;
    if (t[i] == '-' or t[i] == '+' or t[i] == '*') {
        kind = .bullet;
        bullet = t[i];
        width = 1;
        i += 1;
        col += 1;
    } else if (t[i] >= '0' and t[i] <= '9') {
        const digit_start = i;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {}
        const digits = i - digit_start;
        if (digits > 9) return null; // §5.2: at most nine digits
        if (i >= t.len or (t[i] != '.' and t[i] != ')')) return null;
        kind = .ordered;
        delimiter = t[i];
        var n: u32 = 0;
        for (t[digit_start..i]) |b| n = n * 10 + (b - '0');
        start = n;
        width = @intCast(digits + 1);
        i += 1;
        col += width;
    } else {
        return null;
    }

    // The marker must be followed by whitespace or end of line.
    if (i < t.len and t[i] != ' ' and t[i] != '\t') return null;

    // Padding: consume the whitespace after the marker in columns (tabs
    // expand to tab stops), up to six columns past the marker end.
    const save_i = i;
    const save_col = col;
    var ws: u32 = 0;
    while (ws <= 5 and i < t.len and (t[i] == ' ' or t[i] == '\t')) {
        if (t[i] == ' ') {
            col += 1;
            i += 1;
        } else {
            const adv = tab_stop - (col % tab_stop);
            if (adv == 1) i += 1;
            col += 1;
        }
        ws += 1;
    }
    const eol = i >= t.len;

    var blank_start = false;
    var content_indent: u32 = 0;
    var rest: View = undefined;
    if (ws >= 5 or ws < 1 or eol) {
        // Rule 2/3: indented-code-first or blank-start item; content
        // indentation is W+1 and the content begins one column past the
        // marker (the remaining whitespace stays in the item's content).
        content_indent = marker_indent + width + 1;
        i = save_i;
        col = save_col;
        if (ws > 0) {
            if (t[i] == ' ') {
                i += 1;
                col += 1;
            } else {
                const adv = tab_stop - (col % tab_stop);
                if (adv == 1) i += 1;
                col += 1;
            }
        }
        rest = view.after(i, col);
        blank_start = isBlank(rest.line.text);
    } else {
        // Rule 1: ordinary first block; content indentation is W+N and the
        // whitespace is consumed.
        content_indent = marker_indent + width + ws;
        rest = view.after(i, col);
    }

    return .{
        .kind = kind,
        .bullet = bullet,
        .delimiter = delimiter,
        .start = start,
        .width = width,
        .content_indent = content_indent,
        .blank_start = blank_start,
        .rest = rest,
        .can_interrupt = !blank_start and (kind == .bullet or start == 1),
    };
}

/// Applies the §4.1 precedence rule before interpreting a line as a list
/// marker: a thematic break is never a list item, even when its first marker
/// and following whitespace also satisfy the list-marker grammar.
fn tryListMarkerAfterLeafPrecedence(
    view: View,
    thematic_facts: *const ThematicLineFacts,
) ?ListMarker {
    if (isThematicBreak(view, thematic_facts)) return null;
    return tryListMarker(view);
}

/// Are `m`'s items of the same list type as `list_node` (§5.3): same
/// bullet character, or same ordered delimiter?
fn sameListType(list_node: *document.Node, m: ListMarker) bool {
    const list = list_node.data.list;
    return switch (m.kind) {
        .bullet => list.kind == .bullet and list.bullet == m.bullet,
        .ordered => list.kind == .ordered and list.delimiter == m.delimiter,
    };
}

/// Records a blank line for each open list whose direct item is matched by
/// this line. A blank line in a nested list must not make an enclosing list
/// loose; a blank line with no intervening blockquote marker, however, can
/// separate an outer item's nested block from its next block, so all list
/// levels are recorded here and resolved when the next nonblank line shows
/// which level the blank belonged to.
fn noteListBlankLines(containers: *std.ArrayList(ContainerState), matched: usize) void {
    for (containers.items, 0..) |*state, i| {
        if (i >= matched or state.node.tag != .list) continue;
        if (i + 1 >= matched or containers.items[i + 1].node.tag != .list_item) continue;

        var inside_quote = false;
        var j = i + 2;
        while (j < matched) : (j += 1) {
            if (containers.items[j].node.tag == .block_quote) {
                inside_quote = true;
                break;
            }
        }
        if (!inside_quote) state.blank_pending = true;
    }
}

/// A marker at the point where an open list's direct item failed is a
/// sibling item, even when the marker would not be allowed to interrupt a
/// paragraph at the document level (for example `2.` or a blank item). The
/// active list makes the block boundary unambiguous.
fn startsListSibling(
    containers: *const std.ArrayList(ContainerState),
    matched: usize,
    view: View,
    thematic_facts: *const ThematicLineFacts,
) bool {
    if (matched == 0 or matched > containers.items.len) return false;
    if (containers.items[matched - 1].node.tag != .list) return false;
    return tryListMarkerAfterLeafPrecedence(view, thematic_facts) != null;
}

/// Resolves pending blank lines once a nonblank line arrives. A list is loose
/// when the line resumes its direct item after the blank, or starts a sibling
/// item in that list. If a nested list is still the active destination, the
/// blank belongs to that nested list and the enclosing list stays tight.
fn resolveListBlankPending(
    containers: *std.ArrayList(ContainerState),
    matched: usize,
    view: View,
    thematic_facts: *const ThematicLineFacts,
) void {
    const old_len = containers.items.len;
    const marker = tryListMarkerAfterLeafPrecedence(view, thematic_facts);

    var i = old_len;
    while (i > 0) {
        i -= 1;
        const state = &containers.items[i];
        if (state.node.tag != .list or !state.blank_pending) continue;

        // The list is closing before this line. A pending blank at the end of
        // a list does not make that list loose.
        if (i >= matched) {
            state.blank_pending = false;
            continue;
        }

        // A direct sibling marker follows the list itself when its item did
        // not match. This is a blank-separated item pair.
        if (i + 1 >= matched or containers.items[i + 1].node.tag != .list_item) {
            if (i + 1 == matched and marker != null and sameListType(state.node, marker.?)) {
                state.node.data.list.loose = true;
            }
            state.blank_pending = false;
            continue;
        }

        // The direct item matched and there is no nested container left on
        // the old stack: this line is a new direct block after the blank.
        if (matched == i + 2) {
            state.node.data.list.loose = true;
            state.blank_pending = false;
            continue;
        }

        // All nested containers matched, so the line remains inside the
        // nested structure and the blank belongs there.
        if (matched == old_len) {
            state.blank_pending = false;
            continue;
        }

        // A nested list remains matched while its item failed. A list marker
        // at the cursor is a sibling in that nested list; otherwise the
        // nested list is ending and the line resumes the outer item.
        if (matched > i + 2 and
            containers.items[matched - 1].node.tag == .list and
            marker != null)
        {
            state.blank_pending = false;
            continue;
        }

        state.node.data.list.loose = true;
        state.blank_pending = false;
    }
}

/// Is the remainder of a line paragraph continuation text (§5.1 laziness)?
/// That is, it does not start a block that can interrupt a paragraph:
/// a block quote marker, ATX heading, thematic break, a list item that can
/// interrupt (a blank-start item or an ordered item not starting at 1
/// cannot, §5.2 rule 1 exceptions), or an HTML block of types 1-6 (type 7
/// cannot interrupt a paragraph, so a type-7 start *is* continuation text,
/// §4.6). A Setext underline does not join this predicate: it may transform
/// only a paragraph at the same matched container depth, never through a
/// missing container marker.
fn isParagraphContinuationText(
    doc: *document.Document,
    view: View,
    thematic_facts: *const ThematicLineFacts,
) bool {
    if (tryStripBlockQuoteMarker(view) != null) return false;
    if (tryAtxHeading(view) != null) return false;
    if (tryFenceOpen(view) != null) return false;
    if (isThematicBreak(view, thematic_facts)) return false;
    if (tryListMarker(view)) |m| return !m.can_interrupt;
    // Types 1-6 may interrupt a paragraph; a type-7 start may not (so it is
    // passed with allow_type_7=false: a 1-6 match means not continuation).
    if (tryHtmlBlockStart(doc, view, false) != null) return false;
    return true;
}

/// A block whose inlines are parsed in phase 2, once every link reference
/// definition is known.
const PendingInline = union(enum) {
    paragraph: struct { node: *document.Node, lines: []const Paragraph.LineRef },
    heading: struct { node: *document.Node, span: source.Span },
    setext_heading: struct { node: *document.Node, lines: []const Paragraph.LineRef },
    table_cell: struct { node: *document.Node, span: source.Span },
    /// A callout title (extension): the first content line's remainder
    /// after `[!type] `, inline-parsed in phase 2 into
    /// `node.data.block_quote.callout_title_nodes` (docs/CALLOUTS.md §4).
    callout_title: struct { node: *document.Node, span: source.Span },
};

/// A paragraph under construction. `content` is the full raw line span
/// (leading and trailing whitespace included); the inline pass decides what
/// is emitted.
const Paragraph = struct {
    start: u32,
    lines: std.ArrayList(LineRef) = .empty,

    const LineRef = struct {
        content: source.Span,
        terminator: source.Span,
    };
};

/// A link reference definition (§4.7): a label, an optional destination,
/// and an optional title. The destination and title spans are raw source
/// (backslash escapes resolved at emit time, like inline links).
const Definition = struct {
    dest: source.Span,
    title: ?source.Span,
};

/// The document's link reference definitions, keyed by *normalized* label
/// (see `normalizeLabel`). Keys are arena-owned copies. The first
/// definition for a label wins (§4.7: "If there are several matching
/// definitions, the first one takes precedence").
const Definitions = std.StringHashMap(Definition);

fn isBlank(text: []const u8) bool {
    for (text) |b| {
        if (b != ' ' and b != '\t') return false;
    }
    return true;
}

fn appendParagraphLine(doc: *document.Document, paragraph: *?Paragraph, view: View) ParseError!void {
    if (paragraph.* == null) {
        paragraph.* = .{ .start = @intCast(view.line.start) };
    }
    try paragraph.*.?.lines.append(doc.allocator(), .{
        .content = view.line.contentSpan(),
        .terminator = view.line.terminatorSpan(),
    });
}

// ---------------------------------------------------------------------------
// GFM tables extension (§4.10): a header row + delimiter row open a table;
// body rows continue it until a blank line or another block-level structure.
// docs/TABLES.md is the chosen-syntax contract for the corners the GFM spec
// leaves open (pipe-less headers, hyphen counts, `\|` consumption).
// ---------------------------------------------------------------------------

/// The one open table leaf. Rows accumulate as children of the table node
/// (header row first); `data.table.alignment` carries the per-column alignment
/// and the column count. The node's span grows with each row.
const TableBlock = struct {
    node: *document.Node,
    container_depth: usize,
};

fn finishTable(table: *?TableBlock) void {
    table.* = null;
}

/// The parsed delimiter row of a GFM table: the per-column alignment. The
/// column count is `alignment.len` (arena-owned).
const DelimiterParse = struct {
    alignment: []const document.TableAlign,
};

/// True when `span` could be a GFM table header row: it contains at least
/// one unescaped `|` — a real cell separator. Leading/trailing marker
/// pipes count; an escaped `\|` does not. Chosen behavior (docs/TABLES.md
/// §3): a pipe-less line can never be a table header, so `abc` followed by
/// `| --- |` stays a paragraph, and a header whose only pipes are escaped
/// is not a candidate either.
fn tableHeaderCandidate(doc: *document.Document, span: source.Span) bool {
    const bytes = doc.src.bytes;
    var i = span.start;
    while (i < span.end) : (i += 1) {
        if (bytes[i] == '|' and !isEscaped(bytes, i)) return true;
    }
    return false;
}

/// Parses `span` as a GFM table delimiter row (§4.10) and returns the
/// per-column alignment, or null. Delimiter cells must match the chosen
/// grammar `:?-+:?`: at least three hyphens, or at least one hyphen when a
/// colon is present (docs/TABLES.md §3 — the GFM spec's alignment example
/// uses the single-hyphen `:-:`). Leading/trailing pipes are optional and
/// stripped escape-aware; the alignment is arena-allocated on success.
fn tryTableDelimiter(doc: *document.Document, view: View) ParseError!?DelimiterParse {
    const bytes = doc.src.bytes;
    const t = bytes[view.line.contentSpan().start..view.line.contentSpan().end];
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi and (t[lo] == ' ' or t[lo] == '\t')) lo += 1;
    while (hi > lo and (t[hi - 1] == ' ' or t[hi - 1] == '\t')) hi -= 1;
    if (lo < hi and t[lo] == '|') lo += 1;
    if (hi > lo and t[hi - 1] == '|' and !isEscaped(t, hi - 1)) hi -= 1;

    var aligns = std.ArrayList(document.TableAlign).empty;
    defer aligns.deinit(doc.allocator());
    var start = lo;
    var i = lo;
    while (i <= hi) : (i += 1) {
        if (i == hi or (t[i] == '|' and !isEscaped(t, i))) {
            var a = start;
            var b = i;
            while (a < b and (t[a] == ' ' or t[a] == '\t')) a += 1;
            while (b > a and (t[b - 1] == ' ' or t[b - 1] == '\t')) b -= 1;
            const al = parseDelimiterCell(t[a..b]) orelse return null;
            try aligns.append(doc.allocator(), al);
            start = i + 1;
        }
    }
    if (aligns.items.len == 0) return null;
    return .{ .alignment = try aligns.toOwnedSlice(doc.allocator()) };
}

/// One delimiter cell's alignment from its bytes (`---` unaligned, `:---`
/// left, `---:` right, `:---:` center), or null when the cell is not a
/// valid delimiter cell (empty, non-hyphen content, or fewer than the
/// chosen minimum hyphens without a colon).
fn parseDelimiterCell(cell: []const u8) ?document.TableAlign {
    var i: usize = 0;
    var hyphens: usize = 0;
    var has_colon = false;
    if (i < cell.len and cell[i] == ':') {
        has_colon = true;
        i += 1;
    }
    while (i < cell.len and cell[i] == '-') : (i += 1) hyphens += 1;
    if (hyphens == 0) return null;
    var right = false;
    if (i < cell.len and cell[i] == ':') {
        right = true;
        has_colon = true;
        i += 1;
    }
    if (i != cell.len) return null;
    if (hyphens < 3 and !has_colon) return null;
    return if (!has_colon) .none else if (!right) .left else if (cell[0] == ':') .center else .right;
}

/// One cell of a split GFM table row: the trimmed raw content span, a
/// source slice. The cell's inline pass runs the standard machinery over
/// it; only opaque code-span content is post-processed for the consumed
/// `\|` (see `fixCellCodeSpans`).
const CellSpan = struct {
    content: source.Span,
};

/// Splits a GFM table row line into cells, escape-aware (docs/TABLES.md
/// §4): optional leading/trailing pipe markers are dropped (trailing only
/// when unescaped), unescaped `|` separates cells, and `\|` is an escaped
/// pipe — content, never a separator. Spaces/tabs between pipes and cell
/// content are trimmed. The result borrows the source; padding/truncation
/// to the table's column count happens at emit. A pipe-less line yields
/// one cell (the spec's `bar` body-row example).
fn splitRowCells(doc: *document.Document, span: source.Span) ParseError![]CellSpan {
    const bytes = doc.src.bytes;
    const t = bytes[span.start..span.end];
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi and (t[lo] == ' ' or t[lo] == '\t')) lo += 1;
    while (hi > lo and (t[hi - 1] == ' ' or t[hi - 1] == '\t')) hi -= 1;
    if (lo < hi and t[lo] == '|') lo += 1;
    if (hi > lo and t[hi - 1] == '|' and !isEscaped(t, hi - 1)) hi -= 1;

    var cells = std.ArrayList(CellSpan).empty;
    defer cells.deinit(doc.allocator());
    var start = lo;
    var i = lo;
    while (i <= hi) : (i += 1) {
        if (i == hi or (t[i] == '|' and !isEscaped(t, i))) {
            var a = start;
            var b = i;
            while (a < b and (t[a] == ' ' or t[a] == '\t')) a += 1;
            while (b > a and (t[b - 1] == ' ' or t[b - 1] == '\t')) b -= 1;
            try cells.append(doc.allocator(), .{ .content = .{
                .start = @intCast(span.start + a),
                .end = @intCast(span.start + b),
            } });
            start = i + 1;
        }
    }
    return cells.toOwnedSlice(doc.allocator());
}

/// Converts the open single-line paragraph to a GFM table when the current
/// line is a matching delimiter row (§4.10). Returns true when the table
/// was opened (the delimiter line is consumed). The header row keeps the
/// paragraph's cell count; a column mismatch leaves the paragraph open
/// ("a table will not be recognized"). Chosen precedence: a table opening
/// wins over §4.7 link-reference-definition extraction for a single-line
/// paragraph (docs/TABLES.md §6).
fn tryEmitTable(
    doc: *document.Document,
    paragraph: *?Paragraph,
    view: View,
    parent: *document.Node,
    container_depth: usize,
    table: *?TableBlock,
    pending: *std.ArrayList(PendingInline),
) ParseError!bool {
    const p = paragraph.* orelse return false;
    if (p.lines.items.len != 1) return false;
    const header_span = p.lines.items[0].content;
    if (!tableHeaderCandidate(doc, header_span)) return false;
    const delim = (try tryTableDelimiter(doc, view)) orelse return false;
    const cols = delim.alignment.len;
    const header_cells = try splitRowCells(doc, header_span);
    if (header_cells.len != cols) return false;

    const node = try doc.createNode(.table, .{
        .start = @intCast(header_span.start),
        .end = @intCast(view.line.content_end),
    }, .{ .table = .{ .alignment = delim.alignment, .sections = true } });
    try doc.appendChild(parent, node);
    try appendTableRow(doc, node, header_span, header_cells, true, pending);
    paragraph.* = null;
    table.* = .{ .node = node, .container_depth = container_depth };
    return true;
}

/// Appends one row (header or body) to a table: a `table_row` node with
/// one `table_cell` child per column. Cells are padded with empty cells
/// when the line has fewer, and truncated when it has more (GFM §4.10).
/// The cell's header flag and column alignment are resolved here; nonempty
/// cells get a phase-2 inline job.
fn appendTableRow(
    doc: *document.Document,
    table_node: *document.Node,
    line_span: source.Span,
    cells: []CellSpan,
    header: bool,
    pending: *std.ArrayList(PendingInline),
) ParseError!void {
    const alignment = table_node.data.table.alignment;
    const row = try doc.createNode(.table_row, line_span, .{ .table_row = .{} });
    try doc.appendChild(table_node, row);
    for (0..alignment.len) |j| {
        const content = if (j < cells.len) cells[j].content else source.Span{ .start = line_span.start, .end = line_span.start };
        const cell = try doc.createNode(.table_cell, content, .{
            .table_cell = .{ .header = header, .alignment = alignment[j] },
        });
        try doc.appendChild(row, cell);
        if (!content.isEmpty()) {
            try pending.append(doc.allocator(), .{ .table_cell = .{ .node = cell, .span = content } });
        }
    }
}

/// A recognized CommonMark §4.5 opening fence. `info` is the trimmed source
/// range after the fence; an empty range means no info string.
const FenceOpen = struct {
    marker: u8,
    fence_len: usize,
    indent: u8,
    info: source.Span,
};

/// The one open fenced-code leaf. Content is normalized incrementally into
/// the document arena; the node is appended at open time so container order
/// is fixed without buffering sibling blocks.
const FencedCode = struct {
    node: *document.Node,
    marker: u8,
    fence_len: usize,
    indent: u8,
    container_depth: usize,
    content: std.ArrayList(u8) = .empty,
};

/// The one open indented-code leaf (§4.4). Content accumulates literally
/// (chunk separator blank lines included); trailing blank lines are dropped
/// at close (`removeTrailingBlankLines`).
const IndentedCode = struct {
    node: *document.Node,
    container_depth: usize,
    content: std.ArrayList(u8) = .empty,
};

/// The one open HTML block leaf (§4.6; all seven types). Content
/// accumulates the container-stripped remainder of each line *verbatim* —
/// leading spaces and line-ending bytes included — because the block's
/// source lines are not contiguous once container prefixes are stripped
/// (the reference implementation's `add_line` keeps everything from its
/// offset onward). `block_type` selects the end condition: types 1-5 end at
/// the first line containing their terminator; types 6/7 end at a blank
/// line. Either way a containing container closing also ends the block.
const HtmlBlock = struct {
    node: *document.Node,
    container_depth: usize,
    block_type: u8,
    content: std.ArrayList(u8) = .empty,
};

fn appendHtmlBlockLine(doc: *document.Document, out: *std.ArrayList(u8), view: View) ParseError!void {
    try out.appendSlice(doc.allocator(), doc.src.bytes[view.line.start..view.line.end]);
}

/// Publishes the arena-backed verbatim payload.
fn finishHtmlBlock(html: *?HtmlBlock) void {
    const active = html.* orelse return;
    active.node.data = .{ .html_block = active.content.items };
    html.* = null;
}

/// §4.6 type-6 block tag names, matching the reference implementation's
/// scanner list. The match is case-sensitive (cmark's re2c `blocktagname`
/// is lowercase; the spec prose says "case-insensitive", but the corpus is
/// generated by cmark, which routes uppercase tags like `<DIV>` through
/// the type-7 scanner instead).
const html_block_tags = [_][]const u8{
    "address", "article",  "aside",   "base",     "basefont", "blockquote", "body",
    "caption", "center",   "col",     "colgroup", "dd",       "details",    "dialog",
    "dir",     "div",      "dl",      "dt",       "fieldset", "figcaption", "figure",
    "footer",  "form",     "frame",   "frameset", "h1",       "h2",         "h3",
    "h4",      "h5",       "h6",      "head",     "header",   "hr",         "html",
    "iframe",  "legend",   "li",      "link",     "main",     "menu",       "menuitem",
    "nav",     "noframes", "ol",      "optgroup", "option",   "p",          "param",
    "search",  "section",  "summary", "table",    "tbody",    "td",         "tfoot",
    "th",      "thead",    "title",   "tr",       "track",    "ul",
};

/// §4.6 HTML block start conditions, types 1-7. `allow_type_7` is false
/// while a paragraph is open: "All types of HTML blocks except type 7 may
/// interrupt a paragraph." Returns the block type (1-7) or null.
fn tryHtmlBlockStart(doc: *document.Document, view: View, allow_type_7: bool) ?u8 {
    const text = view.line.text;
    const skipped = skipIndent(view, 3) orelse return null;
    const i = skipped.i;
    if (i >= text.len or text[i] != '<') return null;
    if (scanHtmlBlockType1(text, i)) return 1;
    if (scanHtmlBlockType2(text, i)) return 2;
    if (scanHtmlBlockType3(text, i)) return 3;
    if (scanHtmlBlockType4(text, i)) return 4;
    if (scanHtmlBlockType5(text, i)) return 5;
    if (scanHtmlBlockType6(text, i)) return 6;
    if (allow_type_7 and scanHtmlBlockType7(doc.src.bytes, view, i)) return 7;
    return null;
}

/// Type 1 start (§4.6): `<pre`, `<script`, `<style`, or `<textarea`
/// (case-insensitive), followed by a space, a tab, `>`, or the end of the
/// line.
fn scanHtmlBlockType1(text: []const u8, i: usize) bool {
    const names = [_][]const u8{ "pre", "script", "style", "textarea" };
    for (names) |name| {
        if (i + 1 + name.len > text.len) continue;
        if (!eqlIgnoreCase(text[i + 1 .. i + 1 + name.len], name)) continue;
        const after = i + 1 + name.len;
        if (after >= text.len) return true; // end of line
        switch (text[after]) {
            ' ', '\t', '>' => return true,
            else => continue, // `pre` is a prefix of `prex` etc.
        }
    }
    return false;
}

/// Type 2 start: line begins with `<!--`.
fn scanHtmlBlockType2(text: []const u8, i: usize) bool {
    return i + 4 <= text.len and std.mem.eql(u8, text[i .. i + 4], "<!--");
}

/// Type 3 start: line begins with `<?`.
fn scanHtmlBlockType3(text: []const u8, i: usize) bool {
    return i + 2 <= text.len and std.mem.eql(u8, text[i .. i + 2], "<?");
}

/// Type 4 start: line begins with `<!` followed by an ASCII letter.
fn scanHtmlBlockType4(text: []const u8, i: usize) bool {
    return i + 3 <= text.len and text[i + 1] == '!' and isAsciiLetter(text[i + 2]);
}

/// Type 5 start: line begins with `<![CDATA[`.
fn scanHtmlBlockType5(text: []const u8, i: usize) bool {
    return i + 9 <= text.len and std.mem.eql(u8, text[i .. i + 9], "<![CDATA[");
}

/// ASCII case-insensitive equality (used by the §4.6 type-1 start/end
/// scanners, which the spec marks case-insensitive).
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn asciiLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

/// Type 6 start: `<` or `</` + one of the block tag names + a space, tab,
/// vertical tab, form feed, `>`, `/>`, or end of line (cmark's
/// `[<] [/]? blocktagname (spacechar | [/]? [>])`).
fn scanHtmlBlockType6(text: []const u8, i: usize) bool {
    var p = i + 1;
    if (p < text.len and text[p] == '/') p += 1;
    for (html_block_tags) |name| {
        if (p + name.len > text.len or !std.mem.eql(u8, text[p .. p + name.len], name)) continue;
        const after = p + name.len;
        if (after >= text.len) return false;
        switch (text[after]) {
            ' ', '\t', '\x0B', '\x0C', '\r', '\n', '>' => return true,
            '/' => return after + 1 < text.len and text[after + 1] == '>',
            else => continue, // e.g. `head` is a prefix of `header`
        }
    }
    return false;
}

/// Type 7 start: the whole line (after up to three spaces of indentation)
/// is a complete open tag or closing tag plus optional spaces/tabs/form
/// feeds — cmark's `[<] (opentag | closetag) [\t\n\f ]* [\r\n]`. Open
/// tags named `pre`/`script`/`style`/`textarea` are excluded (they are
/// type 1); closing tags of those names are still type 7. The tag must be
/// complete per the §6.6 grammar, so comments/PIs/declarations/CDATA
/// (types 2-5) never match here.
fn scanHtmlBlockType7(bytes: []const u8, view: View, i: usize) bool {
    const tag = scanHtmlTag(bytes, view.line.start + i, view.line.content_end) orelse return false;
    const tag_text = bytes[tag.start..tag.end];
    if (tag_text.len < 2) return false;
    if (tag_text[1] == '/') {
        // Closing tag: no name exclusion (cmark and the spec agree).
    } else if (isAsciiLetter(tag_text[1])) {
        var p: usize = 1;
        while (p < tag_text.len and isTagNameChar(tag_text[p])) : (p += 1) {}
        const name = tag_text[1..p];
        if (std.mem.eql(u8, name, "pre") or std.mem.eql(u8, name, "script") or
            std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "textarea")) return false;
    } else {
        return false; // `<!`/`<?` forms are types 2-5
    }
    var t = tag.end;
    while (t < view.line.content_end) : (t += 1) {
        if (bytes[t] != ' ' and bytes[t] != '\t' and bytes[t] != '\x0C') return false;
    }
    return true;
}

/// §4.6 end conditions for types 1-5: does this line (the container-stripped
/// remainder) end the block? Types 6/7 end at a blank line instead, handled
/// by the loop's blank-line branch.
fn htmlBlockEnded(block_type: u8, text: []const u8) bool {
    return switch (block_type) {
        1 => containsIgnoreCase(text, "</pre>") or
            containsIgnoreCase(text, "</script>") or
            containsIgnoreCase(text, "</style>") or
            containsIgnoreCase(text, "</textarea>"),
        2 => std.mem.indexOf(u8, text, "-->") != null,
        3 => std.mem.indexOf(u8, text, "?>") != null,
        4 => std.mem.indexOfScalar(u8, text, '>') != null,
        5 => std.mem.indexOf(u8, text, "]]>") != null,
        else => false,
    };
}

/// Case-insensitive substring search over ASCII bytes (type-1 end tags are
/// case-insensitive per §4.6).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn tryFenceOpen(view: View) ?FenceOpen {
    const text = view.line.text;
    const skipped = skipIndent(view, 3) orelse return null;
    if (skipped.i >= text.len) return null;

    const indent: u8 = @intCast(skipped.cols);
    const marker = text[skipped.i];
    if (marker != '`' and marker != '~') return null;
    const fence_start = skipped.i;
    var i = fence_start;
    while (i < text.len and text[i] == marker) : (i += 1) {}
    const fence_len = i - fence_start;
    if (fence_len < 3) return null;

    // Backticks anywhere in a backtick fence's info string reject the whole
    // opener. Tilde info strings deliberately allow both marker characters.
    if (marker == '`' and std.mem.indexOfScalar(u8, text[i..], '`') != null) return null;

    var info_start = i;
    while (info_start < text.len and (text[info_start] == ' ' or text[info_start] == '\t')) : (info_start += 1) {}
    var info_end = text.len;
    while (info_end > info_start and (text[info_end - 1] == ' ' or text[info_end - 1] == '\t')) : (info_end -= 1) {}

    return .{
        .marker = marker,
        .fence_len = fence_len,
        .indent = indent,
        .info = .{
            .start = @intCast(view.line.start + info_start),
            .end = @intCast(view.line.start + info_end),
        },
    };
}

fn isFenceClose(view: View, marker: u8, opening_len: usize) bool {
    const text = view.line.text;
    const skipped = skipIndent(view, 3) orelse return false;
    var i = skipped.i;
    if (i >= text.len or text[i] != marker) return false;

    const fence_start = i;
    while (i < text.len and text[i] == marker) : (i += 1) {}
    if (i - fence_start < opening_len) return false;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i == text.len;
}

fn appendFencedContentLine(
    doc: *document.Document,
    fenced: *FencedCode,
    view: View,
) ParseError!void {
    try appendCodeContentLine(doc, &fenced.content, view, fenced.indent);
}

/// Publishes the arena-backed normalized payload. No deinit is required: the
/// document arena owns both the content allocation and optional info copy.
fn finishFencedCode(fenced: *?FencedCode) void {
    const active = fenced.* orelse return;
    const info = active.node.data.code_block.info;
    active.node.data = .{ .code_block = .{
        .content = active.content.items,
        .info = info,
    } };
    fenced.* = null;
}

/// Publishes the arena-backed normalized payload: trailing blank lines are
/// dropped and one final newline re-appended (§4.4).
fn finishIndentedCode(doc: *document.Document, indented: *?IndentedCode) ParseError!void {
    var active = indented.* orelse return;
    removeTrailingBlankLines(&active.content);
    try active.content.append(doc.allocator(), '\n');
    active.node.data = .{ .code_block = .{
        .content = active.content.items,
        .info = null,
    } };
    indented.* = null;
}

/// A Setext heading underline (§4.3): one or more `=` or `-` bytes, with up
/// to three leading spaces and only spaces/tabs after the marker run.
const SetextUnderline = struct {
    level: u8,
};

fn trySetextUnderline(view: View) ?SetextUnderline {
    const text = view.line.text;
    const skipped = skipIndent(view, 3) orelse return null;
    var i = skipped.i;
    if (i >= text.len) return null;

    const marker = text[i];
    if (marker != '=' and marker != '-') return null;
    while (i < text.len and text[i] == marker) : (i += 1) {}
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    if (i != text.len) return null;
    return .{ .level = if (marker == '=') 1 else 2 };
}

/// Once-per-physical-line suffix facts for thematic-break recognition.
/// Container parsing advances only the line's start, so a query at any nested
/// view needs two facts per marker: the last non-whitespace byte of another
/// kind, and the third marker from the end. Both are computed in one reverse
/// scan and make every later suffix query constant-time.
const ThematicLineFacts = struct {
    last_other: [3]?usize,
    third_from_end: [3]?usize,

    fn init(line: source.Line) ThematicLineFacts {
        const markers = [_]u8{ '-', '_', '*' };
        var facts = ThematicLineFacts{
            .last_other = .{ null, null, null },
            .third_from_end = .{ null, null, null },
        };
        var seen = [_]u8{ 0, 0, 0 };

        for (0..line.text.len) |reverse_index| {
            const local = line.text.len - 1 - reverse_index;
            const byte = line.text[local];
            if (byte == ' ' or byte == '\t') continue;
            const absolute = line.start + local;
            for (markers, 0..) |marker, marker_index| {
                if (byte == marker) {
                    if (seen[marker_index] < 3) {
                        seen[marker_index] += 1;
                        if (seen[marker_index] == 3) {
                            facts.third_from_end[marker_index] = absolute;
                        }
                    }
                } else if (facts.last_other[marker_index] == null) {
                    facts.last_other[marker_index] = absolute;
                }
            }
        }
        return facts;
    }
};

/// A thematic break (§4.1): three or more matching `-`, `_`, or `*` bytes,
/// with up to three leading spaces and arbitrary spaces/tabs between or
/// after markers. No other byte is permitted.
fn isThematicBreak(view: View, facts: *const ThematicLineFacts) bool {
    const text = view.line.text;
    const skipped = skipIndent(view, 3) orelse return false;
    const i = skipped.i;
    if (i >= text.len) return false;

    const marker = text[i];
    const marker_index: usize = switch (marker) {
        '-' => 0,
        '_' => 1,
        '*' => 2,
        else => return false,
    };
    const marker_start = view.line.start + i;
    if (facts.last_other[marker_index]) |last_other| {
        if (last_other >= marker_start) return false;
    }
    const third = facts.third_from_end[marker_index] orelse return false;
    return third >= marker_start;
}

/// Returns the first paragraph line that can become Setext heading content,
/// after leading link-reference definitions. Definitions alone are not
/// heading content (§4.7 examples 207/208), and a first content line with
/// more than three spaces of indentation is not eligible (§4.3).
fn setextContentIndex(doc: *document.Document, paragraph: ?Paragraph) ?usize {
    const p = paragraph orelse return null;
    const lines = p.lines.items;
    var k: usize = 0;
    while (k < lines.len) {
        const def = tryParseDefinition(doc, lines[k..]) orelse break;
        k += def.consumed_lines;
    }
    if (k == lines.len) return null;

    const first = doc.src.bytes[lines[k].content.start..lines[k].content.end];
    var indent: usize = 0;
    while (indent < first.len and first[indent] == ' ') : (indent += 1) {}
    if (indent > 3 or (indent < first.len and first[indent] == '\t')) return null;
    return k;
}

/// Converts the open paragraph to a Setext heading. Leading reference
/// definitions are registered exactly as they would be at normal paragraph
/// close; only the remaining lines become heading content. The heading span
/// covers the content lines plus the underline, while inline child spans
/// continue to point only at content bytes.
fn emitSetextHeading(
    doc: *document.Document,
    paragraph: *?Paragraph,
    underline_line: View,
    underline: SetextUnderline,
    parent: *document.Node,
    defs: *Definitions,
    pending: *std.ArrayList(PendingInline),
    options: Options,
) ParseError!bool {
    const k = setextContentIndex(doc, paragraph.*) orelse return false;
    const p = paragraph.*.?;

    var i: usize = 0;
    while (i < k) {
        const def = tryParseDefinition(doc, p.lines.items[i..]) orelse unreachable;
        try registerDefinition(doc, defs, def);
        i += def.consumed_lines;
    }

    const content = p.lines.items[k..];
    var heading_data = document.Heading{ .level = underline.level };
    if (options.heading_attributes) {
        // A trailing `{#id .class}` on the last content line is consumed as
        // the heading's explicit id/class (mutating the LineRef before the
        // phase-2 job reads it).
        const last = &content[content.len - 1];
        const stripped = stripHeadingAttributes(doc.src.bytes, last.content);
        last.content = stripped.content;
        heading_data.id = stripped.id;
        heading_data.class = stripped.class;
    }
    const node = try doc.createNode(.heading, .{
        .start = content[0].content.start,
        .end = @intCast(underline_line.line.content_end),
    }, .{ .heading = heading_data });
    try doc.appendChild(parent, node);
    try pending.append(doc.allocator(), .{
        .setext_heading = .{ .node = node, .lines = content },
    });
    paragraph.* = null;
    return true;
}

/// A parsed link reference definition (§4.7): the label content span and
/// the number of paragraph lines it consumed (the label may span lines).
const ParsedDefinition = struct {
    /// Content between the label's brackets.
    label: source.Span,
    /// Destination content span (sans `<...>` for the angle form).
    dest: source.Span,
    /// Title content span (sans delimiters), when present.
    title: ?source.Span,
    /// Lines consumed by the definition (label lines + destination/title
    /// lines), so the block pass can skip them.
    consumed_lines: usize,
};

/// Parses a link reference definition (§4.7) starting at the first line of
/// `lines`, whose contents may span lines. The grammar:
///
///     [label]: ws? dest ws? title?
///
/// where ws is spaces/tabs including up to one line ending, the label may
/// contain line endings (spec example 202), the destination may not, and
/// the title may. "No further character may occur" after the title (or
/// destination when there is no title) — the definition ends at the end of
/// that line. Returns null when the lines are not a definition (in which
/// case the whole paragraph is ordinary text: definitions cannot interrupt
/// a paragraph, §4.7 example 204).
fn tryParseDefinition(doc: *document.Document, lines: []const Paragraph.LineRef) ?ParsedDefinition {
    const bytes = doc.src.bytes;
    const para_end = lines[lines.len - 1].content.end;

    // Optional indentation: up to three spaces (a leading tab always
    // reaches four columns, which disqualifies the line).
    var i: usize = 0;
    var indent: usize = 0;
    while (i < lines[0].content.len() and bytes[lines[0].content.start + i] == ' ') : (i += 1) {
        indent += 1;
    }
    if (indent > 3) return null;
    if (i < lines[0].content.len() and bytes[lines[0].content.start + i] == '\t') return null;

    // The label: `[` ... first unescaped `]` (may span lines).
    const label = scanDefinitionLabel(bytes, lines, i) orelse return null;

    // The colon, then ws (spaces/tabs including up to one line ending).
    var cur = label.after;
    if (!hasByte(bytes, para_end, cur, ':')) return null;
    cur += 1;
    const after_colon = skipDefWs(bytes, lines, cur, para_end) orelse return null;

    // The destination: angle or bare, on the current line (destinations
    // cannot contain line endings).
    var dest: source.Span = undefined;
    var p = after_colon;
    if (p < para_end and bytes[p] == '<') {
        const end = scanAngleDest(bytes, p + 1, lineEnd(bytes, lines, p)) orelse return null;
        dest = .{ .start = @intCast(p + 1), .end = @intCast(end) };
        p = end + 1;
        // An angle destination must be followed by spaces/tabs or the end
        // of the line (or a line ending): "No further character may occur"
        // after the destination without a whitespace separator, so
        // `[foo]: <bar>(baz)` is not a definition (§4.7 example 201). A
        // bare destination already stops at whitespace (and at an
        // unbalanced `)`); only the angle form can be directly adjacent to
        // a would-be title.
        if (p < para_end and bytes[p] != ' ' and bytes[p] != '\t' and
            bytes[p] != '\n' and bytes[p] != '\r') return null;
    } else {
        const end = scanBareDest(bytes, p, lineEnd(bytes, lines, p)) orelse return null;
        dest = .{ .start = @intCast(p), .end = @intCast(end) };
        p = end;
    }

    // After the destination: optional ws, then an optional title, then end
    // of line. The title must be *separated* from the destination by spaces
    // or tabs (§4.7: `[foo]: <bar>(baz)` is not a definition, because
    // `(baz)` follows the destination with no separating whitespace).
    var title: ?source.Span = null;
    var end_line_end: usize = undefined;
    var q = p;
    const dest_line_end = lineEnd(bytes, lines, p);
    while (q < dest_line_end and (bytes[q] == ' ' or bytes[q] == '\t')) q += 1;

    if (q < dest_line_end) {
        // A title opens on the destination's line. A title opener that
        // fails to parse as a complete title (unclosed, or followed by
        // non-whitespace) invalidates the whole definition: "No further
        // character may occur."
        if (bytes[q] != '"' and bytes[q] != '\'' and bytes[q] != '(') return null;
        const t = scanTitle(bytes, q, para_end) orelse return null;
        title = t.content;
        q = t.end;
        end_line_end = lineEnd(bytes, lines, q);
        while (q < end_line_end) : (q += 1) {
            if (bytes[q] != ' ' and bytes[q] != '\t') return null;
        }
    } else if (nextLineStart(lines, q)) |next_start| {
        // End of the destination's line: the title, if any, begins on the
        // next line (the line ending is itself the separator). A failed
        // title attempt leaves the definition without a title and does not
        // consume the next line (§4.7 example: `[foo]: /url\n"title" ok`
        // is the definition `[foo]: /url` followed by a paragraph).
        var n = next_start;
        const n_end = lineEnd(bytes, lines, n);
        while (n < n_end and (bytes[n] == ' ' or bytes[n] == '\t')) n += 1;
        if (n < n_end and (bytes[n] == '"' or bytes[n] == '\'' or bytes[n] == '(')) {
            if (scanTitle(bytes, n, para_end)) |t| {
                var q2 = t.end;
                const t_line_end = lineEnd(bytes, lines, q2);
                var clean = true;
                while (q2 < t_line_end) : (q2 += 1) {
                    if (bytes[q2] != ' ' and bytes[q2] != '\t') {
                        clean = false;
                        break;
                    }
                }
                if (clean) {
                    title = t.content;
                    end_line_end = t_line_end;
                } else {
                    end_line_end = dest_line_end;
                }
            } else {
                end_line_end = dest_line_end;
            }
        } else {
            end_line_end = dest_line_end;
        }
    } else {
        // Destination on the last line, nothing after it.
        end_line_end = dest_line_end;
    }

    return .{
        .label = label.content,
        .dest = dest,
        .title = title,
        .consumed_lines = consumedLines(bytes, lines, end_line_end),
    };
}

/// Registers a parsed definition; the first definition for a label wins
/// (§4.7: "If there are several matching definitions, the first one takes
/// precedence"). The normalized label is arena-owned.
fn registerDefinition(doc: *document.Document, defs: *Definitions, def: ParsedDefinition) ParseError!void {
    const key = try normalizeLabel(doc, def.label);
    const gop = try defs.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .dest = def.dest, .title = def.title };
    }
}

/// The result of scanning a definition's label.
const ScannedLabel = struct {
    /// Content between the brackets.
    content: source.Span,
    /// Position just past the closing `]`.
    after: usize,
};

/// Scans a link label (§6.3): `[` ... first `]` not backslash-escaped,
/// with no unescaped brackets inside, at least one non-whitespace
/// character, at most 999 characters. The label may span lines (line
/// endings are content, later normalized away). Returns null when the text
/// is not a valid label.
fn scanDefinitionLabel(bytes: []const u8, lines: []const Paragraph.LineRef, start: usize) ?ScannedLabel {
    if (start >= lines[0].content.len()) return null;
    const first = lines[0].content.start + start;
    if (bytes[first] != '[') return null;
    const para_end = lines[lines.len - 1].content.end;

    var p = first + 1;
    var has_nonspace = false;
    var count: usize = 0;
    while (p < para_end) : (p += 1) {
        const b = bytes[p];
        if (b == ']' and !isEscaped(bytes, p)) {
            if (!has_nonspace) return null;
            return .{ .content = .{ .start = @intCast(first + 1), .end = @intCast(p) }, .after = p + 1 };
        }
        if (b == '[' and !isEscaped(bytes, p)) return null; // unescaped bracket inside
        if (b != ' ' and b != '\t' and b != '\n' and b != '\r') has_nonspace = true;
        count += 1;
        if (count > 999) return null; // §6.3: at most 999 characters
    }
    return null;
}

/// The byte at absolute position `pos` is `ch`? (`pos` may be past the end
/// of its line's content but within the paragraph — the colon after a
/// label spanning lines is on the label's last line.)
fn hasByte(bytes: []const u8, para_end: usize, pos: usize, ch: u8) bool {
    return pos < para_end and bytes[pos] == ch;
}

/// Skips definition whitespace (§4.7): spaces/tabs, including up to one
/// line ending. Returns the position after the whitespace, or null when two
/// line endings (or a blank line) appear — the block pass splits paragraphs
/// on blank lines, so this also bounds the scan.
fn skipDefWs(bytes: []const u8, lines: []const Paragraph.LineRef, start: usize, para_end: usize) ?usize {
    _ = lines;
    var p = start;
    var seen_eol = false;
    while (p < para_end) : (p += 1) {
        const b = bytes[p];
        if (b == ' ' or b == '\t') continue;
        if (b == '\n' or b == '\r') {
            if (seen_eol) return null;
            seen_eol = true;
            if (b == '\r' and p + 1 < para_end and bytes[p + 1] == '\n') p += 1;
            continue;
        }
        break;
    }
    return p;
}

/// The end of the line whose content contains absolute position `pos` (the
/// last line's content end if `pos` is past everything). Line contents are
/// disjoint with terminators between them, so this is the byte just before
/// the next line's content.
fn lineEnd(bytes: []const u8, lines: []const Paragraph.LineRef, pos: usize) usize {
    _ = bytes;
    var end = lines[0].content.end;
    for (lines) |ref| {
        if (ref.content.start <= pos) end = ref.content.end;
    }
    return end;
}

/// The content start of the line after the one containing `pos`, or null
/// when `pos` is on the last line.
fn nextLineStart(lines: []const Paragraph.LineRef, pos: usize) ?usize {
    var cur: usize = 0;
    for (lines, 0..) |ref, k| {
        if (ref.content.start <= pos) cur = k;
    }
    if (cur + 1 >= lines.len) return null;
    return lines[cur + 1].content.start;
}

/// Lines consumed by a definition ending at `line_end`: one for each line
/// whose content starts before that position.
fn consumedLines(bytes: []const u8, lines: []const Paragraph.LineRef, line_end: usize) usize {
    _ = bytes;
    var n: usize = 0;
    for (lines) |ref| {
        if (ref.content.start >= line_end) break;
        n += 1;
    }
    return n;
}

/// Normalizes a label (§6.3): strip the brackets (the caller passes the
/// content span), perform the Unicode case fold, strip leading and trailing
/// spaces/tabs/line endings, and collapse consecutive internal
/// spaces/tabs/line endings to a single space. The result is an
/// arena-owned copy — folds can expand (e.g. ẞ -> ss), so it cannot borrow
/// the source.
fn normalizeLabel(doc: *document.Document, content: source.Span) ParseError![]const u8 {
    const bytes = doc.src.bytes;

    // Pass 1: folded length (case folds expand to at most three code
    // points; each of those is at most four UTF-8 bytes).
    var n: usize = 0;
    var i: usize = content.start;
    while (i < content.end) {
        const cp = unicode.decode(bytes, i) orelse bytes[i];
        const f = unicode.caseFold(cp);
        for (0..f.len) |j| n += utf8Len(f.chars[j]);
        i += if (unicode.decode(bytes, i)) |_| unicodeCpLen(bytes, i) else 1;
    }

    const buf = try doc.allocator().alloc(u8, n);
    var k: usize = 0;
    i = content.start;
    while (i < content.end) {
        const cp = unicode.decode(bytes, i) orelse bytes[i];
        const f = unicode.caseFold(cp);
        for (0..f.len) |j| k += encodeCp(buf[k..], f.chars[j]);
        i += if (unicode.decode(bytes, i)) |_| unicodeCpLen(bytes, i) else 1;
    }

    // Strip leading/trailing whitespace (space, tab, line ending) and
    // collapse consecutive internal runs to a single space.
    var start: usize = 0;
    while (start < n and isLabelWs(buf[start])) start += 1;
    var end = n;
    while (end > start and isLabelWs(buf[end - 1])) end -= 1;
    var out: usize = 0;
    var prev_ws = false;
    for (buf[start..end]) |b| {
        if (isLabelWs(b)) {
            if (!prev_ws) {
                buf[out] = ' ';
                out += 1;
                prev_ws = true;
            }
        } else {
            buf[out] = b;
            out += 1;
            prev_ws = false;
        }
    }
    return buf[0..out];
}

fn isLabelWs(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

/// UTF-8 encoded length of a code point.
fn utf8Len(cp: u21) usize {
    return if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
}

/// Byte length of the UTF-8 sequence at position `i`.
fn unicodeCpLen(bytes: []const u8, i: usize) usize {
    const b = bytes[i];
    return if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
}

/// Encodes a code point as UTF-8 into `out[0..]`; returns bytes written.
fn encodeCp(out: []u8, cp: u21) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Closes a paragraph (phase 1). Leading lines that parse as link reference
/// definitions (§4.7) are extracted and registered; the remaining lines
/// form the paragraph node. A paragraph consisting entirely of definitions
/// produces no block at all ("no visible content"). Definitions cannot
/// interrupt a paragraph — only a paragraph *starting* with them is
/// partially or wholly a definition — so extraction stops at the first
/// non-definition line. Inline parsing is deferred to phase 2, where the
/// complete definitions map is available.
/// Closes the open paragraph as a normal `.paragraph` block.
fn closeParagraph(
    doc: *document.Document,
    paragraph: *?Paragraph,
    parent: *document.Node,
    defs: *Definitions,
    pending: *std.ArrayList(PendingInline),
    options: Options,
) ParseError!void {
    return closeParagraphAs(doc, paragraph, parent, defs, pending, options, .paragraph);
}

/// Closes the open paragraph as a block with the given tag. `.paragraph`
/// and `.definition_term` are the two supported tags; both take inline
/// children in phase 2, so the pending job shape is identical.
fn closeParagraphAs(
    doc: *document.Document,
    paragraph: *?Paragraph,
    parent: *document.Node,
    defs: *Definitions,
    pending: *std.ArrayList(PendingInline),
    options: Options,
    node_tag: document.Tag,
) ParseError!void {
    const p = paragraph.* orelse return;
    paragraph.* = null;

    const lines = p.lines.items;

    // Extract leading footnote definitions (Markdown extension) and link
    // reference definitions (§4.7). Either kind may lead a paragraph; the
    // first non-definition line ends the extraction loop.
    var k: usize = 0;
    while (k < lines.len) {
        if (options.footnotes) {
            if (tryParseFootnoteDefinition(doc, lines[k..])) |fd| {
                try registerFootnoteDefinition(doc, fd, lines[k..], pending);
                k += fd.consumed_lines;
                continue;
            }
        }
        const def = tryParseDefinition(doc, lines[k..]) orelse break;
        try registerDefinition(doc, defs, def);
        k += def.consumed_lines;
    }
    if (k == lines.len) return; // entirely definitions: no block

    const remaining = lines[k..];
    const span = source.Span{
        .start = remaining[0].content.start,
        .end = remaining[remaining.len - 1].content.end,
    };
    const data: document.Data = if (node_tag == .paragraph) .{ .paragraph = .{} } else .none;
    const node = try doc.createNode(node_tag, span, data);
    try doc.appendChild(parent, node);
    try pending.append(doc.allocator(), .{ .paragraph = .{ .node = node, .lines = remaining } });
}

/// A parsed Markdown footnote definition (`[^label]:` extension): the label
/// content span (between `[^` and `]`), the content span of the definition
/// line (after `]: `), and the number of paragraph lines consumed (the
/// definition line plus any following lines indented 1–3 columns).
const ParsedFootnoteDefinition = struct {
    label: source.Span,
    content: source.Span,
    consumed_lines: usize,
};

/// Recognizes a Markdown footnote definition line at the start of a
/// paragraph: `[^label]:` with at most three columns of indentation,
/// followed by optional whitespace and the definition content. Continuation
/// lines indented 1–3 columns join the definition's paragraph. Any other
/// shape returns null, so the line stays ordinary paragraph text.
fn tryParseFootnoteDefinition(doc: *document.Document, lines: []const Paragraph.LineRef) ?ParsedFootnoteDefinition {
    const bytes = doc.src.bytes;
    const first = lines[0].content;
    const t = bytes;
    var i = first.start;
    var indent: usize = 0;
    while (i < first.end) : (i += 1) {
        if (t[i] == ' ') {
            indent += 1;
            if (indent > 3) return null;
        } else if (t[i] == '\t') {
            return null; // a leading tab never opens a footnote definition
        } else break;
    }
    if (i + 1 >= first.end or t[i] != '[' or t[i + 1] != '^') return null;
    var j = i + 2;
    while (j < first.end and t[j] != ']') : (j += 1) {}
    if (j >= first.end or j == i + 2) return null; // unclosed or empty label
    var k = j + 1;
    if (k >= first.end or t[k] != ':') return null;
    k += 1;
    while (k < first.end and (t[k] == ' ' or t[k] == '\t')) : (k += 1) {}

    var consumed: usize = 1;
    while (consumed < lines.len) {
        const l = lines[consumed].content;
        var li = l.start;
        var lin: usize = 0;
        while (li < l.end) : (li += 1) {
            if (t[li] == ' ') {
                lin += 1;
            } else if (t[li] == '\t') {
                return null; // tabs in continuation indent are out of scope
            } else break;
        }
        if (lin >= 1 and lin <= 3) {
            consumed += 1;
        } else break;
    }
    return .{
        .label = .{ .start = @intCast(i + 2), .end = @intCast(j) },
        .content = .{ .start = @intCast(k), .end = first.end },
        .consumed_lines = consumed,
    };
}

/// Registers a footnote definition: creates the `.footnote` container with
/// one `.paragraph` child (whose lines are the definition content plus its
/// indented continuations), appends it to `doc.footnotes`, and queues the
/// paragraph for the phase-2 inline pass.
fn registerFootnoteDefinition(
    doc: *document.Document,
    fd: ParsedFootnoteDefinition,
    lines: []const Paragraph.LineRef,
    pending: *std.ArrayList(PendingInline),
) ParseError!void {
    const alloc = doc.allocator();
    const n = fd.consumed_lines;
    const span = source.Span{ .start = lines[0].content.start, .end = lines[n - 1].content.end };
    const fnode = try doc.createNode(.footnote, span, .none);
    const pnode = try doc.createNode(.paragraph, span, .{ .paragraph = .{} });
    try doc.appendChild(fnode, pnode);

    // The definition paragraph's first line is the content after `]: `; the
    // following lines are the indented continuations, verbatim (the inline
    // pass trims leading whitespace).
    const refs = try alloc.alloc(Paragraph.LineRef, n);
    refs[0] = .{ .content = fd.content, .terminator = lines[0].terminator };
    for (1..n) |t| refs[t] = lines[t];
    try pending.append(alloc, .{ .paragraph = .{ .node = pnode, .lines = refs } });
    try doc.footnotes.append(alloc, .{
        .label = doc.src.bytes[fd.label.start..fd.label.end],
        .node = fnode,
    });
}

/// Phase 2 inline pass for a paragraph: discovery -> scan -> link discovery
/// -> match, now with the full definitions map.
fn parseParagraphInlines(
    doc: *document.Document,
    node: *document.Node,
    lines: []const Paragraph.LineRef,
    defs: *Definitions,
    options: Options,
) ParseError!void {
    return parseMultilineBlockInlines(doc, node, lines, defs, options);
}

/// Phase 2 inline pass for Setext content. The underline itself is never part
/// of the inline input; the shared inline line-joining rules remove leading
/// spaces/tabs from every continuation line.
fn parseSetextHeadingInlines(
    doc: *document.Document,
    node: *document.Node,
    lines: []const Paragraph.LineRef,
    defs: *Definitions,
    options: Options,
) ParseError!void {
    return parseMultilineBlockInlines(doc, node, lines, defs, options);
}

fn parseMultilineBlockInlines(
    doc: *document.Document,
    node: *document.Node,
    lines: []const Paragraph.LineRef,
    defs: *Definitions,
    options: Options,
) ParseError!void {
    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());

    // Discovery runs before scanning: code spans and raw HTML tags may span
    // lines, and their content is opaque to the delimiter/escape/break
    // processing. Both are discovered over the whole paragraph, then merged
    // into one resolved construct list (first-come precedence).
    var contents = try doc.allocator().alloc(source.Span, lines.len);
    defer doc.allocator().free(contents);
    for (lines, 0..) |ref, i| contents[i] = ref.content;
    var spans = std.ArrayList(CodeSpan).empty;
    defer spans.deinit(doc.allocator());
    try discoverCodeSpans(doc, contents, &spans);
    var tags = std.ArrayList(HtmlTag).empty;
    defer tags.deinit(doc.allocator());
    try discoverHtmlTags(doc, contents, &tags);
    var constructs = std.ArrayList(Construct).empty;
    defer constructs.deinit(doc.allocator());
    try mergeConstructs(doc, spans.items, tags.items, &constructs);

    // A construct consumed by an autolink (first-come at the `<`) is dead
    // for the whole paragraph, including lines scanned later; `exclude` is
    // the shared floor for the per-line scans.
    var exclude: u32 = 0;
    for (lines, 0..) |ref, i| {
        const has_following_content_line = i + 1 < lines.len;
        const end = analyzeLineEnd(doc.src.bytes, ref.content, has_following_content_line);
        const start = skipLeadingWhitespace(doc.src.bytes, ref.content);
        try scanLine(doc, &items, ref.content, .{ .start = start, .end = end.content_end }, constructs.items, &exclude, options);
        if (has_following_content_line) {
            // A line ending inside a construct (code span content — §6.1
            // "line endings are converted to spaces" — or a raw HTML tag)
            // is construct content, never a break: hard line breaks do not
            // occur inside code spans or HTML tags (§6.1/§6.6).
            if (!terminatorInsideConstruct(ref.terminator, constructs.items)) {
                try items.append(doc.allocator(), .{ .brk = .{ .kind = end.kind, .span = ref.terminator } });
            }
        }
    }
    // Second discovery pass: inline links, images, and reference links
    // (§6.3/§6.4), before emphasis matching.
    const para_end = lines[lines.len - 1].content.end;
    try discoverLinksAndImages(doc, &items, para_end, defs, options);
    try matchInlines(doc, node, items.items, options);
}

/// An ATX heading recognized on a line.
const AtxHeading = struct {
    level: u8,
    /// Span of the heading's inline content after leading/trailing
    /// whitespace stripping and closing-sequence removal.
    content: source.Span,
};

/// Recognizes an ATX heading line per CommonMark §4.2: 1–6 unescaped `#`s,
/// preceded by at most three columns of indentation, followed by spaces/tabs
/// or end of line, with an optional closing sequence of *unescaped* `#`s
/// (preceded by spaces/tabs, followed by only spaces/tabs). Any leading tab
/// reaches four columns from any position except mid-tab, so `skipIndent`
/// naturally rejects over-indented lines. Closing-sequence detection
/// handles backslash escapes (spec example 76).
fn tryAtxHeading(view: View) ?AtxHeading {
    const t = view.line.text;
    const skipped = skipIndent(view, 3) orelse return null;
    var i = skipped.i;
    if (i >= t.len) return null;

    var level: usize = 0;
    while (i < t.len and t[i] == '#') : (i += 1) {
        level += 1;
    }
    if (level == 0 or level > 6) return null;
    if (i < t.len and t[i] != ' ' and t[i] != '\t') return null;

    // Skip the whitespace after the opening sequence.
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}

    const content_start = i;
    var content_end = t.len;
    // §4.2: raw contents are stripped of leading and trailing spaces/tabs.
    while (content_end > content_start and
        (t[content_end - 1] == ' ' or t[content_end - 1] == '\t'))
    {
        content_end -= 1;
    }
    // Optional closing sequence: a trailing run of *unescaped* `#`s,
    // preceded by spaces/tabs (or comprising the entire content), which is
    // stripped along with the whitespace before it. A single pass: in
    // `# foo # #` only the final `#` is the closing sequence.
    if (content_end > content_start and t[content_end - 1] == '#') {
        var run_start = content_end;
        while (run_start > content_start) {
            if (t[run_start - 1] != '#') break;
            if (isEscaped(t, run_start - 1)) break;
            run_start -= 1;
        }
        if (run_start < content_end) {
            if (run_start == content_start or
                t[run_start - 1] == ' ' or t[run_start - 1] == '\t')
            {
                content_end = run_start;
                while (content_end > content_start and
                    (t[content_end - 1] == ' ' or t[content_end - 1] == '\t'))
                {
                    content_end -= 1;
                }
            }
        }
    }

    return .{
        .level = @intCast(level),
        .content = .{
            .start = @intCast(view.line.start + content_start),
            .end = @intCast(view.line.start + content_end),
        },
    };
}

/// Strips a trailing heading attribute list (`{#id .class}`, extension)
/// from an ATX or Setext heading's content span. The attribute list must be
/// the last thing on the line, preceded by whitespace; `#id` becomes the
/// heading's explicit id and `.class` its class (first token wins; values
/// are raw source slices). Returns the reduced content span and the parsed
/// attributes, or the input unchanged when no valid list is present.
fn stripHeadingAttributes(bytes: []const u8, content: source.Span) struct {
    content: source.Span,
    id: ?[]const u8,
    class: ?[]const u8,
} {
    if (content.len() < 3 or bytes[content.end - 1] != '}') return .{ .content = content, .id = null, .class = null };

    // Find the `{` opening the trailing brace group (the last unescaped
    // `{` before the final `}`, with no `}` between it and the end).
    var open: ?usize = null;
    var i = content.end - 1;
    while (i > content.start) {
        i -= 1;
        if (bytes[i] == '}') break;
        if (bytes[i] == '{' and !isEscaped(bytes, i)) {
            open = i;
            break;
        }
    }
    const o = open orelse return .{ .content = content, .id = null, .class = null };
    if (o > content.start and bytes[o - 1] != ' ' and bytes[o - 1] != '\t') return .{ .content = content, .id = null, .class = null };
    // Parse `#id` and `.class` tokens separated by whitespace.
    var id: ?[]const u8 = null;
    var cls: ?[]const u8 = null;
    var idx = o + 1;
    while (idx < content.end - 1) {
        if (bytes[idx] == ' ' or bytes[idx] == '\t') {
            idx += 1;
            continue;
        }
        if (bytes[idx] == '#' or bytes[idx] == '.') {
            const is_id = bytes[idx] == '#';
            var j = idx + 1;
            while (j < content.end - 1 and bytes[j] != ' ' and bytes[j] != '\t') : (j += 1) {}
            if (j == idx + 1) return .{ .content = content, .id = null, .class = null }; // empty token
            if (is_id) {
                if (id == null) id = bytes[idx + 1 .. j];
            } else {
                if (cls == null) cls = bytes[idx + 1 .. j];
            }
            idx = j;
            continue;
        }
        return .{ .content = content, .id = null, .class = null }; // unknown token shape: not an IAL
    }

    // Strip the IAL (and the whitespace before it) from the content.
    var new_end = o;
    while (new_end > content.start and (bytes[new_end - 1] == ' ' or bytes[new_end - 1] == '\t')) new_end -= 1;
    return .{
        .content = .{ .start = content.start, .end = @intCast(new_end) },
        .id = id,
        .class = cls,
    };
}

fn emitHeading(
    doc: *document.Document,
    view: View,
    heading: AtxHeading,
    parent: *document.Node,
    pending: *std.ArrayList(PendingInline),
    options: Options,
) ParseError!void {
    var heading_data = document.Heading{ .level = heading.level };
    var content = heading.content;
    if (options.heading_attributes) {
        const stripped = stripHeadingAttributes(doc.src.bytes, content);
        content = stripped.content;
        heading_data.id = stripped.id;
        heading_data.class = stripped.class;
    }
    const node = try doc.createNode(.heading, view.line.contentSpan(), .{ .heading = heading_data });
    try doc.appendChild(parent, node);
    if (!content.isEmpty()) {
        try pending.append(doc.allocator(), .{ .heading = .{ .node = node, .span = content } });
    }
}

/// Phase 2 inline pass for a GFM table cell (§4.10): the cell's raw
/// content parses like a single-line block's inlines (code spans, raw
/// HTML, links/images, emphasis). After matching, code-span nodes are
/// post-processed for the pipe escape the row splitter consumed
/// (docs/TABLES.md §5): code-span content is opaque to the inline pass, so
/// a `\|` there keeps its backslash and must be dropped to match the
/// spec's §4.10 example (`` `\|` `` renders `<code>|</code>`).
fn parseTableCellInlines(
    doc: *document.Document,
    node: *document.Node,
    content: source.Span,
    defs: *Definitions,
    options: Options,
) ParseError!void {
    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());
    var spans = std.ArrayList(CodeSpan).empty;
    defer spans.deinit(doc.allocator());
    try discoverCodeSpans(doc, &[_]source.Span{content}, &spans);
    var tags = std.ArrayList(HtmlTag).empty;
    defer tags.deinit(doc.allocator());
    try discoverHtmlTags(doc, &[_]source.Span{content}, &tags);
    var constructs = std.ArrayList(Construct).empty;
    defer constructs.deinit(doc.allocator());
    try mergeConstructs(doc, spans.items, tags.items, &constructs);
    var exclude: u32 = 0;
    try scanLine(doc, &items, content, content, constructs.items, &exclude, options);
    try discoverLinksAndImages(doc, &items, content.end, defs, options);
    try matchInlines(doc, node, items.items, options);
    try fixCellCodeSpans(doc, node);
}

/// Returns a copy of `s` with the backslash dropped from every `\|` pair
/// Reproduces the §4.10 pipe escape in the one place the inline pass
/// cannot resolve it: code-span content is opaque, so a backslash directly
/// before a pipe survives there and must be dropped (`` `\|` `` →
/// `<code>|</code>`). Image alts flattened from a cell carry the same
/// artifact (a code span inside an image description). Iterative walk, so
/// hostile cell nesting cannot overflow the call stack.
fn fixCellCodeSpans(doc: *document.Document, cell: *document.Node) ParseError!void {
    var it = try document.Document.Iterator.init(doc.allocator(), cell);
    defer it.deinit();
    while (try it.next()) |n| {
        switch (n.tag) {
            .code_span => {
                const content = n.data.code_span;
                if (std.mem.indexOf(u8, content, "\\|") == null) continue;
                n.data.code_span = try dropPipeEscapeBackslashes(doc, content);
            },
            .image => {
                const alt = n.data.image.alt;
                if (std.mem.indexOf(u8, alt, "\\|") == null) continue;
                n.data.image.alt = try dropPipeEscapeBackslashes(doc, alt);
            },
            else => {},
        }
    }
}

/// Returns a copy of `s` with the backslash dropped from every `\|` pair
/// — the pipe positions whose preceding backslash run is odd, i.e. exactly
/// the positions the row splitter consumed as escaped pipes. Other bytes
/// (including other backslash escapes) are kept verbatim.
fn dropPipeEscapeBackslashes(doc: *document.Document, s: []const u8) ParseError![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(doc.allocator());
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '|' and i > 0 and isEscaped(s, i)) {
            try buf.appendSlice(doc.allocator(), s[run_start .. i - 1]);
            try buf.append(doc.allocator(), '|');
            run_start = i + 1;
        }
    }
    try buf.appendSlice(doc.allocator(), s[run_start..]);
    return buf.toOwnedSlice(doc.allocator());
}

/// Phase 2 inline pass for a heading (see `emitHeading`).
fn parseHeadingInlines(
    doc: *document.Document,
    node: *document.Node,
    content: source.Span,
    defs: *Definitions,
    options: Options,
) ParseError!void {
    var items = std.ArrayList(InlineItem).empty;
    defer items.deinit(doc.allocator());
    var spans = std.ArrayList(CodeSpan).empty;
    defer spans.deinit(doc.allocator());
    try discoverCodeSpans(doc, &[_]source.Span{content}, &spans);
    var tags = std.ArrayList(HtmlTag).empty;
    defer tags.deinit(doc.allocator());
    try discoverHtmlTags(doc, &[_]source.Span{content}, &tags);
    var constructs = std.ArrayList(Construct).empty;
    defer constructs.deinit(doc.allocator());
    try mergeConstructs(doc, spans.items, tags.items, &constructs);
    var exclude: u32 = 0;
    try scanLine(doc, &items, content, content, constructs.items, &exclude, options);
    try discoverLinksAndImages(doc, &items, content.end, defs, options);
    try matchInlines(doc, node, items.items, options);
}

/// Phase 2 inline pass for a callout title (extension): the title parses
/// like a heading's inline content (single span, same pass — so
/// emphasis, links, and wikilinks work in titles, docs/CALLOUTS.md §7).
/// The parsed nodes are collected into a temporary container and stored
/// in `node.data.block_quote.callout_title_nodes`, keeping the
/// blockquote's `children` a pure block list (the body).
fn parseCalloutTitleInlines(
    doc: *document.Document,
    node: *document.Node,
    content: source.Span,
    defs: *Definitions,
    options: Options,
) ParseError!void {
    var temp = try doc.createNode(.paragraph, content, .none);
    try parseHeadingInlines(doc, temp, content, defs, options);
    node.data.block_quote.callout_title_nodes = try temp.children.toOwnedSlice(doc.allocator());
}

// ---------------------------------------------------------------------------
// Inline pass: scan -> flat item list.
// ---------------------------------------------------------------------------

const BreakKind = enum { soft, hard };

const LineEnd = struct {
    kind: BreakKind,
    /// Byte offset where emitted content ends: the trailing whitespace run
    /// (and a hard-break backslash, if present) is consumed.
    content_end: u32,
};

/// Analyzes the end of a paragraph line per §6.7: a trailing run of
/// whitespace with two or more spaces is a hard break; an unescaped
/// backslash before a following content line is a hard break; otherwise the
/// break is soft. Tabs in the trailing run do not trigger a hard break. The
/// entire trailing run is consumed in every case. A final backslash with no
/// following content line stays literal (example 644, and Setext §4.3).
fn analyzeLineEnd(bytes: []const u8, span: source.Span, has_following_content_line: bool) LineEnd {
    var end = span.end;
    var spaces: usize = 0;
    while (end > span.start and (bytes[end - 1] == ' ' or bytes[end - 1] == '\t')) : (end -= 1) {
        if (bytes[end - 1] == ' ') spaces += 1;
    }
    const trailing = span.end - end;
    if (has_following_content_line and
        trailing == 0 and
        end > span.start and
        bytes[end - 1] == '\\' and
        !isEscaped(bytes, end - 1))
    {
        return .{ .kind = .hard, .content_end = end - 1 };
    }
    if (spaces >= 2) return .{ .kind = .hard, .content_end = end };
    return .{ .kind = .soft, .content_end = end };
}

fn skipLeadingWhitespace(bytes: []const u8, span: source.Span) u32 {
    var i = span.start;
    while (i < span.end and (bytes[i] == ' ' or bytes[i] == '\t')) : (i += 1) {}
    return i;
}

/// A recognized autolink (§6.8). `span` covers `<...>`; `content` is the
/// bytes between the angle brackets, verbatim (backslash escapes are inert
/// inside autolinks); `is_email` selects the `mailto:` href prefix.
const AutolinkScan = struct {
    span: source.Span,
    content: source.Span,
    is_email: bool,
};

/// A transient inline item in the flat list produced by the scan phase.
/// Allocated from the document arena; dies with the document.
const InlineItem = union(enum) {
    /// A run of literal text. The span is the emitted range (leading and
    /// trailing whitespace already trimmed); escapes are resolved at emit
    /// time, so the span may include `\X` pairs.
    text: source.Span,
    /// A maximal run of unescaped `*` or `_` characters (spec §6.2).
    delimiter: DelimiterRun,
    /// A soft or hard line break between two lines of the block.
    brk: struct { kind: BreakKind, span: source.Span },
    /// A matched code span (§6.1): `span` covers the full construct
    /// (opening backtick .. closing backtick), `content` the raw bytes
    /// between the backtick strings (may span line endings). The content is
    /// opaque: no delimiters, escapes, or breaks are recognized inside it.
    code_span: struct { span: source.Span, content: source.Span },
    /// An unescaped `[` or `]` (§6.6). `[`s are potential link openers;
    /// `]`s trigger link discovery. Brackets that never become part of a
    /// link are emitted as literal text.
    bracket: struct { ch: u8, span: source.Span },
    /// A discovered inline link (§6.6): `span` covers the whole construct
    /// `[text](dest "title")`; `children` are the link-text items (never
    /// containing another link item); `dest`/`title` are raw source spans
    /// of the destination (sans `<...>`) and title content (sans
    /// delimiters), resolved for escapes at emit time.
    link: LinkItem,
    /// A discovered inline image (§6.7): `span` covers the whole construct
    /// `![desc](dest "title")`; `children` are the description items (an
    /// image description may contain links and images, so unlike a link
    /// these may contain link/image items); `dest`/`title` are raw source
    /// spans like a link's. The description is flattened to the `alt`
    /// string at emit time (docs/IMAGES-PARSING.md §3).
    image: ImageItem,
    /// A recognized autolink (§6.8): `span` covers `<...>`, `content` the
    /// bytes between the angle brackets (verbatim — backslash escapes are
    /// inert inside autolinks), `is_email` selects the `mailto:` href
    /// prefix. Opaque to the delimiter stack and link discovery, like
    /// `code_span` (docs/AUTOLINKS.md §2).
    autolink: AutolinkScan,
    /// A recognized raw HTML tag (§6.6): `span` covers the whole construct
    /// (`<` .. `>`), which may span lines. Opaque to the delimiter stack,
    /// link discovery, and break processing (docs/RAW-HTML.md §2); the
    /// renderer writes the source bytes verbatim.
    raw_html: RawHtmlItem,
    /// A Markdown footnote reference (`[^label]`, extension): `span` covers
    /// the whole construct and `label` the bytes between `^` and `]`.
    /// Leaf item: opaque to the delimiter stack.
    footnote: FootnoteItem,
    /// A recognized wikilink (`[[target]]` / `[[target|label]]`, extension):
    /// `span` covers the whole `[[…]]` construct and `content` the raw
    /// bytes between the delimiters. The target/label split and trim are
    /// validated at discovery (`splitWikilinkContent`) and re-derived at
    /// emit time. Leaf item: opaque to the delimiter stack and link
    /// discovery (docs/WIKILINKS.md §2).
    wikilink: WikilinkItem,
};

/// A Markdown footnote reference item (extension). See `InlineItem.footnote`.
const FootnoteItem = struct {
    span: source.Span,
    label: source.Span,
};

/// A recognized wikilink item (extension). See `InlineItem.wikilink`.
const WikilinkItem = struct {
    /// The whole `[[…]]` construct.
    span: source.Span,
    /// The raw bytes between `[[` and `]]` (before trimming/splitting).
    content: source.Span,
};

/// A raw HTML tag item (§6.6): the whole construct span. The tag's bytes
/// are rendered verbatim from the source, so no payload is needed.
const RawHtmlItem = struct {
    span: source.Span,
};

/// A discovered inline link (§6.6). See `InlineItem.link`.
const LinkItem = struct {
    span: source.Span,
    children: std.ArrayList(InlineItem),
    dest: source.Span,
    title: ?source.Span,
};

/// A discovered inline image (§6.7). See `InlineItem.image`.
const ImageItem = struct {
    span: source.Span,
    children: std.ArrayList(InlineItem),
    dest: source.Span,
    title: ?source.Span,
};

/// The source range any item covers. Every variant carries a span; this is
/// the union-safe accessor.
fn itemSpan(item: InlineItem) source.Span {
    return switch (item) {
        .text => |s| s,
        .delimiter => |d| d.span,
        .brk => |b| b.span,
        .code_span => |c| c.span,
        .bracket => |b| b.span,
        .link => |l| l.span,
        .image => |im| im.span,
        .autolink => |a| a.span,
        .raw_html => |h| h.span,
        .footnote => |fn_| fn_.span,
        .wikilink => |wk| wk.span,
    };
}

/// Mutates the source range of any item (every variant carries a span).
fn setItemSpan(item: *InlineItem, span: source.Span) void {
    switch (item.*) {
        .text => |*s| s.* = span,
        .delimiter => |*d| d.span = span,
        .brk => |*b| b.span = span,
        .code_span => |*c| c.span = span,
        .bracket => |*b| b.span = span,
        .link => |*l| l.span = span,
        .image => |*im| im.span = span,
        .autolink => |*a| a.span = span,
        .raw_html => |*h| h.span = span,
        .footnote => |*fn_| fn_.span = span,
        .wikilink => |*wk| wk.span = span,
    }
}

/// A code span discovered by `discoverCodeSpans`. Spans are disjoint and
/// sorted by `span.start`.
const CodeSpan = struct {
    /// Opening backtick start .. closing backtick end.
    span: source.Span,
    /// Raw bytes between the backtick strings (the content before §6.1
    /// normalization; may include line endings).
    content: source.Span,
};

/// A raw HTML tag discovered by `discoverHtmlTags` (§6.6). Spans are
/// disjoint (each match consumes its whole construct) and sorted by
/// `span.start`.
const HtmlTag = struct {
    /// `<` .. `>` of the whole construct, including any line endings.
    span: source.Span,
};

/// A paragraph-level opaque inline construct: a code span or a raw HTML
/// tag, resolved for first-come precedence. `mergeConstructs` drops any
/// construct that starts inside an already-accepted one, so the list is
/// disjoint and sorted by `span.start`. The scan consumes constructs in
/// order; everything inside them is opaque to the delimiter stack, link
/// discovery, and break processing.
const Construct = struct {
    kind: enum { code_span, html_tag },
    span: source.Span,
    /// Code spans: the raw content bounds (see `CodeSpan.content`).
    /// Unused for HTML tags.
    content: source.Span,
};

/// Discovers code spans (§6.1) over the concatenated raw content of the
/// given spans (one entry per line of the block). Backtick strings are
/// maximal runs of backticks whose first character is not backslash-escaped
/// (§2.4 example 14: `\`not code` is literal). Each string opens a code
/// span closed by the *next* string of equal length; strings of other
/// lengths are skipped (§6.1), and everything between opener and closer is
/// opaque (interior backticks never reopen).
///
/// The closer scan is deliberately *not* escape-aware: a backslash inside
/// the would-be content is literal ("backslash escapes do not work in code
/// spans"), so it cannot escape a following backtick — `\`foo\`bar` `
/// closes at the backtick after `foo\` (spec example).
fn discoverCodeSpans(doc: *document.Document, contents: []const source.Span, spans: *std.ArrayList(CodeSpan)) ParseError!void {
    const bytes = doc.src.bytes;
    const para_end = contents[contents.len - 1].end;
    const para_start = contents[0].start;

    var i = para_start;
    while (i < para_end) {
        // Normal-text scan: a run starts at an unescaped backtick that is
        // not itself part of a longer run ("neither preceded nor followed
        // by a backtick").
        const at_run_start = bytes[i] == '`' and
            !isEscaped(bytes, i) and
            (i == para_start or bytes[i - 1] != '`');
        if (at_run_start) {
            var e = i + 1;
            while (e < para_end and bytes[e] == '`') : (e += 1) {}
            const want = e - i;

            // Escape-free forward scan for a closing string of equal
            // length; longer/shorter strings are skipped.
            var j = e;
            var closer_start: ?u32 = null;
            while (j < para_end) : (j += 1) {
                if (bytes[j] != '`' or bytes[j - 1] == '`') continue;
                var k = j + 1;
                while (k < para_end and bytes[k] == '`') : (k += 1) {}
                if (k - j == want) {
                    closer_start = @intCast(j);
                    break;
                }
                j = k - 1; // different length: keep scanning past it
            }
            if (closer_start) |cs| {
                const close_end = cs + @as(u32, @intCast(want));
                try spans.append(doc.allocator(), .{
                    .span = .{ .start = @intCast(i), .end = close_end },
                    .content = .{ .start = @intCast(e), .end = cs },
                });
                i = close_end;
                continue;
            }
            i = e; // unclosed: literal backticks, resume after the run
            continue;
        }
        i += 1;
    }
}

/// True if the line terminator `[term.start, term.end)` lies inside a
/// resolved construct (code span content or raw HTML tag) that continues on
/// a later line. Used to suppress break items: the line ending is then
/// construct content, not a soft/hard break. The resolved list already
/// dropped first-come losers, so a terminator inside a dead span is a
/// normal break.
fn terminatorInsideConstruct(term: source.Span, constructs: []const Construct) bool {
    for (constructs) |c| {
        if (c.span.start > term.start) return false; // sorted; later constructs are past it
        if (term.start < c.span.end) return true;
    }
    return false;
}

/// Merges the discovered code spans and HTML tags into one resolved,
/// overlap-free list ordered by start. First-come wins: a construct whose
/// start lies inside an already-accepted construct's span is dropped (the
/// earlier construct's opener precedes it, so per §6.1 the earlier
/// construct is parsed and the later one never starts). Both input lists
/// are sorted and internally disjoint, so a linear walk suffices
/// (docs/RAW-HTML.md §2).
fn mergeConstructs(
    doc: *document.Document,
    spans: []const CodeSpan,
    tags: []const HtmlTag,
    out: *std.ArrayList(Construct),
) ParseError!void {
    var si: usize = 0;
    var ti: usize = 0;
    var last_end: u32 = 0;
    while (si < spans.len or ti < tags.len) {
        const span_next = si < spans.len;
        const tag_next = ti < tags.len;
        const from_tag = if (!span_next) true else if (!tag_next) false else tags[ti].span.start < spans[si].span.start;
        if (from_tag) {
            if (tags[ti].span.start >= last_end) {
                try out.append(doc.allocator(), .{
                    .kind = .html_tag,
                    .span = tags[ti].span,
                    .content = .{ .start = 0, .end = 0 },
                });
                last_end = tags[ti].span.end;
            }
            ti += 1;
        } else {
            if (spans[si].span.start >= last_end) {
                try out.append(doc.allocator(), .{
                    .kind = .code_span,
                    .span = spans[si].span,
                    .content = spans[si].content,
                });
                last_end = spans[si].span.end;
            }
            si += 1;
        }
    }
}

/// Discovers raw HTML tags (§6.6) over the concatenated raw content of the
/// given spans (one entry per line of the block). The scan is escape-aware
/// at the `<` only: `\<` is literal, and backslash escapes are inert
/// *inside* tags, so a matched construct is consumed wholesale. A construct
/// that fails leaves its `<` alone — it may still be an autolink (§6.8) or
/// literal text, resolved later in the scan.
fn discoverHtmlTags(doc: *document.Document, contents: []const source.Span, tags: *std.ArrayList(HtmlTag)) ParseError!void {
    const bytes = doc.src.bytes;
    const para_start = contents[0].start;
    const para_end = contents[contents.len - 1].end;
    var i = para_start;
    while (i < para_end) {
        if (bytes[i] == '<' and !isEscaped(bytes, i)) {
            if (scanHtmlTag(bytes, i, para_end)) |span| {
                try tags.append(doc.allocator(), .{ .span = span });
                i = span.end;
                continue;
            }
        }
        i += 1;
    }
}

/// Scans a raw HTML construct (§6.6) starting at the `<` at `pos`, bounded
/// by `end` (the paragraph end — tags may span lines). Tries the six
/// construct forms in spec order; returns the construct span or null.
fn scanHtmlTag(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    if (pos + 2 > end or bytes[pos] != '<') return null;
    // `<!--` comment (`<!-->`, `<!--->`, or `<!--` ... `-->`).
    if (pos + 4 <= end and bytes[pos + 1] == '!' and bytes[pos + 2] == '-' and bytes[pos + 3] == '-') {
        return scanComment(bytes, pos, end);
    }
    if (bytes[pos + 1] == '?') return scanProcessingInstruction(bytes, pos, end);
    if (bytes[pos + 1] == '!') {
        // CDATA before the declaration form: `<![CDATA[` does not match
        // `<!` + letter, so the order is a matter of clarity, not behavior.
        if (pos + 9 <= end and std.mem.startsWith(u8, bytes[pos..end], "<![CDATA[")) {
            return scanCdata(bytes, pos, end);
        }
        return scanDeclaration(bytes, pos, end);
    }
    if (bytes[pos + 1] == '/') return scanClosingTag(bytes, pos, end);
    return scanOpenTag(bytes, pos, end);
}

/// §6.6 whitespace chunk: spaces/tabs, at most one line ending, then
/// spaces/tabs again ("optional spaces, tabs, and up to one line ending").
/// Returns the position after, or null when a second consecutive line
/// ending appears (which fails the containing tag).
fn skipTagWhitespace(bytes: []const u8, i: usize, end: usize) ?usize {
    var p = i;
    while (p < end and (bytes[p] == ' ' or bytes[p] == '\t')) : (p += 1) {}
    if (p < end and lineEndingLen(bytes, p) > 0) {
        p += lineEndingLen(bytes, p);
        while (p < end and (bytes[p] == ' ' or bytes[p] == '\t')) : (p += 1) {}
        if (p < end and lineEndingLen(bytes, p) > 0) return null;
    }
    return p;
}

/// `<!-->` (5 bytes) or `<!--->` (6 bytes), or the general form
/// `<!--` + (no `-->`) + `-->`.
fn scanComment(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    if (pos + 5 <= end and bytes[pos + 4] == '>') {
        return .{ .start = @intCast(pos), .end = @intCast(pos + 5) }; // <!-->
    }
    if (pos + 6 <= end and bytes[pos + 4] == '-' and bytes[pos + 5] == '>') {
        return .{ .start = @intCast(pos), .end = @intCast(pos + 6) }; // <!--->
    }
    var j = pos + 4;
    while (j + 2 < end) : (j += 1) {
        if (bytes[j] == '-' and bytes[j + 1] == '-' and bytes[j + 2] == '>') {
            return .{ .start = @intCast(pos), .end = @intCast(j + 3) };
        }
    }
    return null;
}

/// `<?` + (no `?>`) + `?>`.
fn scanProcessingInstruction(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    var j = pos + 2;
    while (j + 1 < end) : (j += 1) {
        if (bytes[j] == '?' and bytes[j + 1] == '>') {
            return .{ .start = @intCast(pos), .end = @intCast(j + 2) };
        }
    }
    return null;
}

/// `<!` + ASCII letter + (no `>`) + `>`.
fn scanDeclaration(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    if (pos + 3 > end or !isAsciiLetter(bytes[pos + 2])) return null;
    var j = pos + 3;
    while (j < end) : (j += 1) {
        if (bytes[j] == '>') return .{ .start = @intCast(pos), .end = @intCast(j + 1) };
    }
    return null;
}

/// `<![CDATA[` + (no `]]>`) + `]]>`.
fn scanCdata(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    var j = pos + 9;
    while (j + 2 < end) : (j += 1) {
        if (bytes[j] == ']' and bytes[j + 1] == ']' and bytes[j + 2] == '>') {
            return .{ .start = @intCast(pos), .end = @intCast(j + 3) };
        }
    }
    return null;
}

/// `</` + tag name + whitespace chunk + `>` (no attributes, no `/`).
fn scanClosingTag(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    var p = pos + 2;
    if (p >= end or !isAsciiLetter(bytes[p])) return null;
    p += 1;
    while (p < end and isTagNameChar(bytes[p])) : (p += 1) {}
    const w = skipTagWhitespace(bytes, p, end) orelse return null;
    if (w < end and bytes[w] == '>') return .{ .start = @intCast(pos), .end = @intCast(w + 1) };
    return null;
}

/// §6.6 unquoted attribute value terminator set: whitespace, `"`, `'`, `=`,
/// `<`, `>`, or `` ` ``.
fn isUnquotedValueStop(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or
        b == '"' or b == '\'' or b == '=' or b == '<' or b == '>' or b == '`';
}

/// `<` + tag name + zero or more attributes + whitespace chunk + optional
/// `/` + `>`. Each attribute is a whitespace chunk, an attribute name, and
/// an optional value specification (whitespace chunk + `=` + whitespace
/// chunk + value), where a value is unquoted (nonempty), single-quoted, or
/// double-quoted.
fn scanOpenTag(bytes: []const u8, pos: usize, end: usize) ?source.Span {
    var p = pos + 1;
    if (p >= end or !isAsciiLetter(bytes[p])) return null;
    p += 1;
    while (p < end and isTagNameChar(bytes[p])) : (p += 1) {}
    // Attributes and tail. Each component boundary is a whitespace chunk
    // (spaces/tabs and at most one line ending) followed by `>`, `/`+`>`,
    // or an attribute name. An attribute name must be preceded by at least
    // one whitespace byte: the spec attaches the chunk to the attribute,
    // spec example 622 (`<a href='bar'title=title>`) fails without it, and
    // `<a:b>` must fall through to the autolink attempt. The chunk probed
    // after an attribute name doubles as the next component's boundary
    // chunk when no `=` follows, so the scan tracks whether a boundary was
    // already consumed and whether it was nonempty.
    var boundary_done = false;
    var boundary_nonempty = false;
    while (true) {
        var chunk: usize = undefined;
        var nonempty: bool = undefined;
        if (boundary_done) {
            chunk = p;
            nonempty = boundary_nonempty;
            boundary_done = false;
        } else {
            chunk = skipTagWhitespace(bytes, p, end) orelse return null;
            nonempty = chunk != p;
        }
        if (chunk >= end) return null;
        const b = bytes[chunk];
        if (b == '>') return .{ .start = @intCast(pos), .end = @intCast(chunk + 1) };
        if (b == '/') {
            // The optional `/` must be immediately before `>` (`<a/ >` fails).
            if (chunk + 1 < end and bytes[chunk + 1] == '>') return .{ .start = @intCast(pos), .end = @intCast(chunk + 2) };
            return null;
        }
        // Attribute name: letter/`_`/`:` first, then name chars.
        if (!(isAsciiLetter(b) or b == '_' or b == ':')) return null;
        if (!nonempty) return null; // attributes require preceding whitespace
        var q = chunk + 1;
        while (q < end and isAttrNameChar(bytes[q])) : (q += 1) {}
        // Optional value specification: a whitespace chunk, then `=`.
        const eq = skipTagWhitespace(bytes, q, end) orelse return null;
        if (eq < end and bytes[eq] == '=') {
            const vstart = skipTagWhitespace(bytes, eq + 1, end) orelse return null;
            if (vstart >= end) return null;
            const v = bytes[vstart];
            if (v == '"' or v == '\'') {
                // Quoted value: scan to the closing quote (may contain line
                // endings and any other bytes; backslash is not special).
                var r = vstart + 1;
                while (r < end and bytes[r] != v) : (r += 1) {}
                if (r >= end) return null; // unterminated
                p = r + 1;
            } else {
                // Unquoted value: a nonempty run of non-terminator chars.
                var r = vstart;
                while (r < end and !isUnquotedValueStop(bytes[r])) : (r += 1) {}
                if (r == vstart) return null; // empty unquoted value
                p = r;
            }
        } else {
            // No value spec: the probe chunk is the next component's
            // boundary chunk, already consumed.
            p = eq;
            boundary_done = true;
            boundary_nonempty = eq != q;
        }
    }
}

// ---------------------------------------------------------------------------
// Inline pass: link discovery (scan -> match, second discovery pass).
// ---------------------------------------------------------------------------

/// The result of parsing an inline link's `(...)` part.
const LinkParts = struct {
    /// Position just after the link's closing `)`.
    paren_end: u32,
    /// The destination's content (excluding `<...>` for the angle form;
    /// empty for `()` / `(<> )`).
    dest: source.Span,
    /// The title's content (excluding its delimiters), when present.
    title: ?source.Span,
};

/// Parses an inline link's `(...)` part starting at `pos`, which must be
/// the `(` immediately following the link text's `]` (§6.6: "followed
/// immediately by a left parenthesis"). The four components — `(`, link
/// destination, link title, `)` — may be separated by spaces, tabs, and up
/// to one line ending; the destination may not contain a line ending, the
/// title may. Returns null when the text is not a valid inline link, in
/// which case the caller keeps the brackets as literal text.
fn tryParseLink(bytes: []const u8, pos: usize, para_end: usize) ?LinkParts {
    if (pos >= para_end or bytes[pos] != '(') return null;
    var p = pos + 1;
    p = skipLinkSep(bytes, p, para_end) orelse return null;

    var dest: ?source.Span = null;
    if (p < para_end) {
        if (bytes[p] == '<') {
            // Starts with `<`: only the angle form can follow (§6.6 "does
            // not start with `<`" for the bare form); a failed angle scan
            // fails the whole link.
            const end = scanAngleDest(bytes, p + 1, para_end) orelse return null;
            dest = .{ .start = @intCast(p + 1), .end = @intCast(end) };
            p = end + 1;
        } else if (scanBareDest(bytes, p, para_end)) |end| {
            dest = .{ .start = @intCast(p), .end = @intCast(end) };
            p = end;
        }
    }
    p = skipLinkSep(bytes, p, para_end) orelse return null;

    var title: ?source.Span = null;
    if (p < para_end and (bytes[p] == '"' or bytes[p] == '\'' or bytes[p] == '(')) {
        const t = scanTitle(bytes, p, para_end) orelse return null;
        title = t.content;
        p = t.end;
        p = skipLinkSep(bytes, p, para_end) orelse return null;
    }
    if (p < para_end and bytes[p] == ')') {
        return .{
            .paren_end = @intCast(p + 1),
            .dest = dest orelse .{ .start = @intCast(pos + 1), .end = @intCast(pos + 1) },
            .title = title,
        };
    }
    return null;
}

/// Skips the whitespace separating link components (§6.6): spaces, tabs,
/// and up to one line ending. Two line endings (or a blank line, which the
/// block pass would have split anyway) make the separator invalid.
/// `\r\n` counts as a single line ending.
fn skipLinkSep(bytes: []const u8, start: usize, para_end: usize) ?usize {
    var p = start;
    var seen_eol = false;
    while (p < para_end) : (p += 1) {
        const b = bytes[p];
        if (b == ' ' or b == '\t') continue;
        if (b == '\n' or b == '\r') {
            if (seen_eol) return null;
            seen_eol = true;
            if (b == '\r' and p + 1 < para_end and bytes[p + 1] == '\n') p += 1;
            continue;
        }
        break;
    }
    return p;
}

/// Scans a bare link destination (§6.6): a nonempty sequence that does not
/// start with `<`, contains no spaces or ASCII control characters, and
/// includes parentheses only when backslash-escaped or balanced. Stops at
/// the first space/control character, at an unescaped `)` when the paren
/// depth is zero (that `)` is the link's own closing parenthesis), or at
/// the paragraph end. Returns null when the sequence is empty or the parens
/// are unbalanced at the stop point (e.g. `[link](foo(and(bar))` fails).
///
/// DoS guard: the spec lets implementations "impose limits on parentheses
/// nesting to avoid performance issues" (and at least three levels must
/// work), so a depth beyond `max_dest_depth` — or a scan longer than
/// `max_link_scan` — fails the destination instead of letting a hostile
/// `[a]([a]([a](...` line make every `]` rescan the whole paragraph.
fn scanBareDest(bytes: []const u8, start: usize, para_end: usize) ?usize {
    var p = start;
    var depth: usize = 0;
    while (p < para_end) : (p += 1) {
        if (p - start > max_link_scan) return null;
        const b = bytes[p];
        if (b == ' ' or b < 0x20 or b == 0x7f) break;
        if (b == '\\' and p + 1 < para_end and isAsciiPunctuation(bytes[p + 1])) {
            p += 1; // escaped character: literal, and not a paren/space
            continue;
        }
        if (b == '(') {
            depth += 1;
            if (depth > max_dest_depth) return null;
        } else if (b == ')') {
            if (depth == 0) break; // the link's closing parenthesis
            depth -= 1;
        }
    }
    if (p == start or depth != 0) return null;
    return p;
}

/// Scans an angle-bracketed link destination (`<...>`, §6.6): content with
/// no line endings and no unescaped `<` or `>`; the closing `>` must be
/// unescaped ("angle brackets that enclose links must be unescaped").
/// Returns the position of the closing `>`; null when the scan runs past
/// `max_link_scan` bytes (DoS guard, see `scanBareDest`).
fn scanAngleDest(bytes: []const u8, start: usize, para_end: usize) ?usize {
    var p = start;
    while (p < para_end) : (p += 1) {
        if (p - start > max_link_scan) return null;
        const b = bytes[p];
        if (b == '\n' or b == '\r') return null; // destinations cannot contain line endings
        if (b == '<' and !isEscaped(bytes, p)) return null;
        if (b == '>' and !isEscaped(bytes, p)) return p;
    }
    return null;
}

const TitleParts = struct {
    /// Content between the delimiters (raw bytes; line endings kept).
    content: source.Span,
    /// Position just after the closing delimiter.
    end: usize,
};

/// Scans a link title (§6.6): `"..."`, `'...'`, or `(...)`, where the
/// delimiting character appears inside only backslash-escaped (for the
/// paren form, the first unescaped `)` closes — a chosen reading, see
/// docs/FEATURE-MATRIX). Titles may span line endings (the block pass
/// bounds them: a blank line splits the paragraph). Returns null when no
/// closing delimiter is found, or when the scan runs past `max_link_scan`
/// bytes (DoS guard, see `scanBareDest`).
fn scanTitle(bytes: []const u8, start: usize, para_end: usize) ?TitleParts {
    const open = bytes[start];
    const close: u8 = if (open == '(') ')' else open;
    var p = start + 1;
    while (p < para_end) : (p += 1) {
        if (p - start > max_link_scan) return null;
        const b = bytes[p];
        if (b == '\\' and p + 1 < para_end and isAsciiPunctuation(bytes[p + 1])) {
            p += 1; // escaped character: literal, never the closer
            continue;
        }
        if (b == close) {
            return .{
                .content = .{ .start = @intCast(start + 1), .end = @intCast(p) },
                .end = p + 1,
            };
        }
    }
    return null;
}

/// DoS guards for link-component scans (see `scanBareDest`): a paren depth
/// cap the spec explicitly permits, and a generous per-component scan cap.
const max_dest_depth: usize = 32;
const max_link_scan: usize = 2048;

/// Discovers inline links and images (§6.6/§6.7) and reference links
/// (§6.6 reference forms) in the item list, restructuring it in place.
/// Walks the list with a bracket stack; on a `]` whose nearest `[` or `![`
/// opener is followed by a valid `(...)` construct in the source, or whose
/// nearest `[` is followed by a reference label (full/collapsed/shortcut)
/// with a matching definition, splices the bracket range — plus the items
/// covering the consumed `(...)`/label bytes — into a single `link` or
/// `image` item whose children are the bracket-range items, and drops the
/// matched opener and everything trapped above it. Brackets that never form
/// a construct stay in the list and emit as literal text.
///
/// Nesting follows the spec appendix's *look for link or image*: a formed
/// *link* inactivates every earlier `[` opener (links cannot contain links,
/// innermost wins), while a formed *image* inactivates nothing (an image
/// description may contain links and images). Inactivity is decided by a
/// monotone check — a `[` at out position `p` is inactive iff some link has
/// formed with an opener at a larger out position, so nothing is re-marked
/// and matching stays linear (docs/IMAGES-PARSING.md §2). `![` openers are
/// never inactive. Reference precedence (§6.6): an inline link (`(...)`),
/// then full (`[text][label]`), then collapsed (`[text][]`), then shortcut
/// (`[text]`); a failed inline `(...)` does not block the shortcut form
/// (spec example 561). Reference forms apply to both `[` and `![` openers
/// (reference-style images per docs/REFERENCE-IMAGES.md). Runs
/// before emphasis matching: link/image items are opaque to the delimiter
/// The trimmed target/label spans of a wikilink's raw content, or null
/// when the shape is malformed: an empty or whitespace-only target or
/// label, an empty target on the label-side-only form (`[[|x]]`), or a
/// label containing a second `|` (`[[a|b|c]]`) (docs/WIKILINKS.md §1).
/// Trimming removes leading/trailing spaces and tabs; the returned spans
/// are the trimmed sub-ranges of `content`.
const WikilinkParts = struct {
    target: source.Span,
    label: ?source.Span,
};

fn splitWikilinkContent(bytes: []const u8, content: source.Span) ?WikilinkParts {
    var end = content.end;
    while (end > content.start and (bytes[end - 1] == ' ' or bytes[end - 1] == '\t')) end -= 1;
    var start = content.start;
    while (start < end and (bytes[start] == ' ' or bytes[start] == '\t')) start += 1;
    if (start >= end) return null; // empty after trim

    var pipe: ?usize = null;
    var i = start;
    while (i < end) : (i += 1) {
        if (bytes[i] == '|') {
            pipe = i;
            break;
        }
    }
    const pipe_at = pipe orelse return .{ .target = .{ .start = @intCast(start), .end = @intCast(end) }, .label = null };
    if (pipe_at <= start) return null; // `[[|x]]`: empty target

    // Label: after the pipe, trimmed, non-empty, no second pipe.
    var ls = pipe_at + 1;
    while (ls < end and (bytes[ls] == ' ' or bytes[ls] == '\t')) ls += 1;
    var le = end;
    while (le > ls and (bytes[le - 1] == ' ' or bytes[le - 1] == '\t')) le -= 1;
    if (ls >= le) return null; // `[[x|]]`: empty label
    var j = ls;
    while (j < le) : (j += 1) {
        if (bytes[j] == '|') return null; // `[[a|b|c]]`: extra pipe
    }
    return .{
        .target = .{ .start = @intCast(start), .end = @intCast(pipe_at) },
        .label = .{ .start = @intCast(ls), .end = @intCast(le) },
    };
}

/// A wikilink that ends up inside a formed link's display text (or an
/// image description) is demoted to literal text: wikilinks are opaque
/// inside link text (docs/WIKILINKS.md §2), so `[a [[b]] c](/url)` keeps
/// `[[b]]` literal — a nested `<a>` inside `<a>` would be invalid HTML.
/// Runs on the copied children list; `out` in the caller is unaffected.
fn demoteWikilinks(children: *std.ArrayList(InlineItem)) void {
    for (children.items) |*c| {
        if (c.* == .wikilink) {
            const span = c.wikilink.span;
            c.* = .{ .text = span };
        }
    }
}

/// stack, and their children are matched separately (link text as a fresh
/// inline scope; image descriptions flattened to the alt string at emit
/// time).
fn discoverLinksAndImages(
    doc: *document.Document,
    items: *std.ArrayList(InlineItem),
    para_end: u32,
    defs: *Definitions,
    options: Options,
) ParseError!void {
    const bytes = doc.src.bytes;
    var out = std.ArrayList(InlineItem).empty;
    var stack = std.ArrayList(usize).empty;
    defer stack.deinit(doc.allocator());

    const old = items.items;
    var max_link_opener_out: usize = 0;
    var i: usize = 0;
    while (i < old.len) : (i += 1) {
        const item = old[i];
        // Wikilink extension: `[[` is recognized ahead of link brackets
        // (docs/WIKILINKS.md §2). Two consecutive unescaped `[` bracket
        // items start a wikilink attempt: scan items for the first pair of
        // consecutive `]` brackets (the greedy closer), reject a raw `[[`
        // inside the content and any malformed target/label shape, and
        // emit a `.wikilink` item consuming the whole construct. On any
        // failure the `[[` is emitted as literal text and the scan resumes
        // after it — the bracket machinery never re-visits the `[[`
        // (atomic fallback).
        if (options.wikilinks and item == .bracket and item.bracket.ch == '[' and
            i + 1 < old.len and old[i + 1] == .bracket and old[i + 1].bracket.ch == '[')
        {
            var close: ?usize = null;
            var j = i + 2;
            while (j + 1 < old.len) : (j += 1) {
                if (old[j] == .bracket and old[j].bracket.ch == ']' and
                    old[j + 1] == .bracket and old[j + 1].bracket.ch == ']')
                {
                    close = j;
                    break;
                }
            }
            var matched = false;
            if (close) |c| {
                const content = source.Span{
                    .start = old[i + 1].bracket.span.end,
                    .end = old[c].bracket.span.start,
                };
                // The target may not contain `[[` (docs/WIKILINKS.md §1):
                // checked on the raw content bytes.
                var no_nested = true;
                var k = content.start;
                while (k + 1 < content.end) : (k += 1) {
                    if (bytes[k] == '[' and bytes[k + 1] == '[') {
                        no_nested = false;
                        break;
                    }
                }
                if (no_nested and splitWikilinkContent(bytes, content) != null) {
                    matched = true;
                    try out.append(doc.allocator(), .{
                        .wikilink = .{
                            .span = .{ .start = item.bracket.span.start, .end = old[c + 1].bracket.span.end },
                            .content = content,
                        },
                    });
                    i = c + 1;
                }
            }
            if (!matched) {
                // Atomic fallback: both `[`s as literal text.
                try out.append(doc.allocator(), .{ .text = item.bracket.span });
                try out.append(doc.allocator(), .{ .text = old[i + 1].bracket.span });
                i += 1;
            }
            continue;
        }
        if (item == .bracket and (item.bracket.ch == '[' or item.bracket.ch == '!')) {
            try out.append(doc.allocator(), item);
            try stack.append(doc.allocator(), out.items.len - 1);
            continue;
        }
        if (item == .bracket and item.bracket.ch == ']') {
            if (stack.items.len == 0) {
                try out.append(doc.allocator(), item);
                continue;
            }
            const o = stack.items[stack.items.len - 1];
            if (out.items[o].bracket.ch == '[' and max_link_opener_out > o) {
                // Inactive opener (a `[` below a formed link): remove it
                // and return a literal `]` — it must not reach a `![`
                // below it (spec appendix; docs/IMAGES-PARSING.md §2).
                _ = stack.pop();
                try out.append(doc.allocator(), item);
                continue;
            }
            const close_end = item.bracket.span.end;
            const is_image = out.items[o].bracket.ch == '!';
            const open_start = out.items[o].bracket.span.start;

            // The bracket text span: between the opener and this `]`. A `[`
            // opener is one byte; a `![` opener spans two, so the text
            // starts past the bang. Used for collapsed/shortcut labels and
            // as the link text for image alt-flattening inputs.
            const text = source.Span{ .start = open_start + (if (is_image) @as(u32, 2) else 1), .end = close_end - 1 };

            // 0. Markdown footnote reference (extension): `[^label]` whose
            // label names a registered definition. Consumes the bracket
            // pair; like an image, a footnote ref inactivates nothing.
            if (options.footnotes and !is_image and text.len() > 1 and bytes[text.start] == '^') {
                const label = source.Span{ .start = text.start + 1, .end = text.end };
                if (!label.isEmpty() and footnoteDefined(doc, label)) {
                    out.shrinkRetainingCapacity(o);
                    try out.append(doc.allocator(), .{
                        .footnote = .{ .span = .{ .start = open_start, .end = close_end }, .label = label },
                    });
                    while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                    continue;
                }
            }

            // 1. Inline link/image: `(` immediately after the `]`.
            if (close_end < para_end and bytes[close_end] == '(') {
                if (tryParseLink(bytes, close_end, para_end)) |lp| {
                    // Children: the items between the opener and `]`. Never
                    // contains a link (one would have killed this opener
                    // first); an image's description may contain links and
                    // images.
                    var children = std.ArrayList(InlineItem).empty;
                    try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);
                    demoteWikilinks(&children); // wikilinks stay literal inside link text

                    // Consume the `(...)` items: everything after the `]` up
                    // to (not including) the closing paren. The last
                    // consumed item may extend past the closing paren (e.g.
                    // `[foo](/uri) and more`) — truncate it so its tail
                    // stays literal text after the construct. The tail is
                    // re-appended *after* the shrink below, which otherwise
                    // would clobber it (bug: trailing text after an inline
                    // link was dropped).
                    var j = i + 1;
                    while (j < old.len and itemSpan(old[j]).start < lp.paren_end) : (j += 1) {}
                    const keep_tail = j > i + 1 and itemSpan(old[j - 1]).end > lp.paren_end;
                    if (keep_tail) {
                        setItemSpan(&old[j - 1], .{ .start = lp.paren_end, .end = itemSpan(old[j - 1]).end });
                    }

                    out.shrinkRetainingCapacity(o);
                    if (is_image) {
                        try out.append(doc.allocator(), .{
                            .image = .{
                                .span = .{ .start = open_start, .end = lp.paren_end },
                                .children = children,
                                .dest = lp.dest,
                                .title = lp.title,
                            },
                        });
                    } else {
                        try out.append(doc.allocator(), .{
                            .link = .{
                                .span = .{ .start = open_start, .end = lp.paren_end },
                                .children = children,
                                .dest = lp.dest,
                                .title = lp.title,
                            },
                        });
                        // A formed link inactivates every earlier `[` (the
                        // monotone check above); record its out position so
                        // those openers are recognized as dead.
                        max_link_opener_out = @max(max_link_opener_out, o);
                    }
                    if (keep_tail) {
                        try out.append(doc.allocator(), old[j - 1]);
                    }
                    // The matched opener and everything trapped above it
                    // were consumed by the construct; entries below stay
                    // (their activity is decided by the monotone check).
                    while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                    i = j - 1; // the `(...)` items were consumed
                    continue;
                }
                // A `(` that fails to parse as an inline construct falls
                // through to the reference forms below (§6.6 example:
                // `[foo](not a link)` with `[foo]: /url1` → shortcut
                // reference, with `(not a link)` as literal text).
            }

            // 2. Reference forms: a `[` immediately after the `]` is a full
            // or collapsed reference; nothing else is a shortcut. Applies to
            // both links and images (spec appendix: the procedure is
            // uniform; reference-style images per docs/REFERENCE-IMAGES.md).
            if (close_end < para_end and bytes[close_end] == '[') {
                // Collapsed: `[]` — the label is the bracket text itself.
                if (close_end + 1 < para_end and bytes[close_end + 1] == ']') {
                    if (try tryResolveReference(doc, defs, text)) |def| {
                        var children = std.ArrayList(InlineItem).empty;
                        try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);

                        var j = i + 1;
                        while (j < old.len and itemSpan(old[j]).start < close_end + 2) : (j += 1) {}
                        const keep_tail = j > i + 1 and itemSpan(old[j - 1]).end > close_end + 2;
                        if (keep_tail) {
                            setItemSpan(&old[j - 1], .{ .start = close_end + 2, .end = itemSpan(old[j - 1]).end });
                        }

                        out.shrinkRetainingCapacity(o);
                        if (is_image) {
                            try out.append(doc.allocator(), .{
                                .image = .{
                                    .span = .{ .start = open_start, .end = close_end + 2 },
                                    .children = children,
                                    .dest = def.dest,
                                    .title = def.title,
                                },
                            });
                        } else {
                            try out.append(doc.allocator(), .{
                                .link = .{
                                    .span = .{ .start = open_start, .end = close_end + 2 },
                                    .children = children,
                                    .dest = def.dest,
                                    .title = def.title,
                                },
                            });
                            max_link_opener_out = @max(max_link_opener_out, o);
                        }
                        if (keep_tail) {
                            try out.append(doc.allocator(), old[j - 1]);
                        }
                        while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                        i = j - 1;
                        continue;
                    }
                    // An unresolved `[]` still blocks the shortcut form.
                    _ = stack.pop();
                    try out.append(doc.allocator(), item);
                    continue;
                }

                // Full: `[label]` — the label is scanned and resolved.
                if (scanRefLabel(bytes, close_end, para_end)) |lab| {
                    if (try tryResolveReference(doc, defs, lab.content)) |def| {
                        var children = std.ArrayList(InlineItem).empty;
                        try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);

                        // Consume items covering the label `[...]`.
                        var j = i + 1;
                        while (j < old.len and itemSpan(old[j]).start < lab.after) : (j += 1) {}
                        const keep_tail = j > i + 1 and itemSpan(old[j - 1]).end > lab.after;
                        if (keep_tail) {
                            setItemSpan(&old[j - 1], .{ .start = @intCast(lab.after), .end = itemSpan(old[j - 1]).end });
                        }

                        out.shrinkRetainingCapacity(o);
                        if (is_image) {
                            try out.append(doc.allocator(), .{
                                .image = .{
                                    .span = .{ .start = open_start, .end = @intCast(lab.after) },
                                    .children = children,
                                    .dest = def.dest,
                                    .title = def.title,
                                },
                            });
                        } else {
                            try out.append(doc.allocator(), .{
                                .link = .{
                                    .span = .{ .start = open_start, .end = @intCast(lab.after) },
                                    .children = children,
                                    .dest = def.dest,
                                    .title = def.title,
                                },
                            });
                            max_link_opener_out = @max(max_link_opener_out, o);
                        }
                        if (keep_tail) {
                            try out.append(doc.allocator(), old[j - 1]);
                        }
                        while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                        i = j - 1;
                        continue;
                    }
                }
                // A `[` that does not resolve (or an invalid label) still
                // blocks the shortcut form: "not followed by [] or a link
                // label".
                _ = stack.pop();
                try out.append(doc.allocator(), item);
                continue;
            }

            // 3. Shortcut reference: `[text]` not followed by `[]` or a
            // link label (§6.6) — i.e. not followed by `[`. A `(` after a
            // failed inline link does not block the shortcut (§6.6 example
            // `[foo](not a link)` with `[foo]: /url1`). Applies to links
            // and images alike.
            if (close_end >= para_end or bytes[close_end] != '[') {
                if (try tryResolveReference(doc, defs, text)) |def| {
                    var children = std.ArrayList(InlineItem).empty;
                    try children.appendSlice(doc.allocator(), out.items[o + 1 ..]);
                    demoteWikilinks(&children); // wikilinks stay literal inside link text

                    out.shrinkRetainingCapacity(o);
                    if (is_image) {
                        try out.append(doc.allocator(), .{
                            .image = .{
                                .span = .{ .start = open_start, .end = close_end },
                                .children = children,
                                .dest = def.dest,
                                .title = def.title,
                            },
                        });
                    } else {
                        try out.append(doc.allocator(), .{
                            .link = .{
                                .span = .{ .start = open_start, .end = close_end },
                                .children = children,
                                .dest = def.dest,
                                .title = def.title,
                            },
                        });
                        max_link_opener_out = @max(max_link_opener_out, o);
                    }
                    while (stack.items.len > 0 and stack.items[stack.items.len - 1] >= o) _ = stack.pop();
                    continue;
                }
            }

            // Not a link/image: the opener can never match a later `]`.
            _ = stack.pop();
            try out.append(doc.allocator(), item);
            continue;
        }
        try out.append(doc.allocator(), item);
    }

    items.* = out; // moved; the old buffer stays in the arena
}

/// Whether a footnote definition with the exact (case-sensitive) label is
/// registered. Linear scan: definitions are few and the check runs only
/// when a `[^...]` candidate is found.
fn footnoteDefined(doc: *document.Document, label: source.Span) bool {
    const bytes = doc.src.bytes;
    for (doc.footnotes.items) |fd| {
        if (std.mem.eql(u8, fd.label, bytes[label.start..label.end])) return true;
    }
    return false;
}

/// The result of scanning a reference label following a `]`.
const ScannedRefLabel = struct {
    /// Content between the label's brackets.
    content: source.Span,
    /// Position just past the label's closing `]`.
    after: usize,
};

/// Scans a reference label `[...]` starting at the `[` at position `pos`
/// (immediately after a link text's `]`). The label ends at the first `]`
/// not backslash-escaped, with no unescaped brackets inside and at least
/// one non-whitespace character (§6.6). Returns null for an invalid label.
fn scanRefLabel(bytes: []const u8, pos: usize, para_end: usize) ?ScannedRefLabel {
    if (pos >= para_end or bytes[pos] != '[') return null;
    var p = pos + 1;
    var has_nonspace = false;
    var count: usize = 0;
    while (p < para_end) : (p += 1) {
        const b = bytes[p];
        if (b == ']' and !isEscaped(bytes, p)) {
            if (!has_nonspace) return null;
            return .{ .content = .{ .start = @intCast(pos + 1), .end = @intCast(p) }, .after = p + 1 };
        }
        if (b == '[' and !isEscaped(bytes, p)) return null; // unescaped bracket inside
        if (b != ' ' and b != '\t' and b != '\n' and b != '\r') has_nonspace = true;
        count += 1;
        if (count > 999) return null; // §6.6: at most 999 characters
    }
    return null;
}

/// Looks up the definition matching a reference label, normalizing the
/// label for comparison. Returns null when there is no match.
fn tryResolveReference(
    doc: *document.Document,
    defs: *Definitions,
    label: source.Span,
) ParseError!?Definition {
    const key = try normalizeLabel(doc, label);
    if (defs.get(key)) |def| return def;
    return null;
}

/// A delimiter run, classified once at scan time. `can_open`/`can_close`
/// follow rules 1–8; the same flags serve emphasis and strong emphasis
/// because for both `*` and `_` the single- and double-delimiter rules
/// classify runs identically (docs/INLINE-PARSING.md §6).
const DelimiterRun = struct {
    ch: u8,
    /// Bytes consumed by closer matches, from the front of the run.
    front_used: u32 = 0,
    /// Bytes consumed by opener matches, from the back of the run.
    back_used: u32 = 0,
    /// Full original run span in the source.
    span: source.Span,
    can_open: bool,
    can_close: bool,

    /// Delimiters not yet consumed by any match. The remaining bytes are the
    /// run's middle: [span.start + front_used, span.end - back_used).
    fn len(self: *const DelimiterRun) u32 {
        return @intCast(self.span.len() - self.front_used - self.back_used);
    }
};

/// Scans one line's raw content span into `items`. Flanking is computed
/// against the *raw* span (so trailing whitespace and line boundaries
/// classify runs correctly); emitted text is clamped to `emit`, which is
/// where the leading/trailing trimming decided by the block pass applies.
///
/// `spans` (sorted, disjoint) are the block's code spans; positions inside
/// a span are opaque — a code_span item is appended at the opening
/// backtick, and everything through the closing backtick is skipped.
/// §2.1 ASCII letter: `[a-zA-Z]` (the first character of a scheme).
fn isAsciiLetter(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

/// §6.8 scheme character: an ASCII letter, digit, `+`, `.`, or `-`.
fn isSchemeChar(b: u8) bool {
    return isAsciiLetter(b) or (b >= '0' and b <= '9') or b == '+' or b == '.' or b == '-';
}

/// §6.8 email local-part character (the HTML5 regex's first class):
/// `[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]`.
fn isEmailLocalChar(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
        else => false,
    };
}

/// §6.8 email domain-label character: an ASCII letter or digit, or `-`.
fn isEmailDomainChar(b: u8) bool {
    return isAsciiLetter(b) or (b >= '0' and b <= '9') or b == '-';
}

/// §6.6 tag-name character: an ASCII letter, digit, or `-`.
fn isTagNameChar(b: u8) bool {
    return isAsciiLetter(b) or (b >= '0' and b <= '9') or b == '-';
}

/// §6.6 attribute-name character: an ASCII letter, digit, `_`, `.`, `:`,
/// or `-` (the first character is restricted to letter/`_`/`:`).
fn isAttrNameChar(b: u8) bool {
    return isAsciiLetter(b) or (b >= '0' and b <= '9') or b == '_' or b == '.' or b == ':' or b == '-';
}

/// The length of a CommonMark line ending at `i` (`\n`, `\r\n`, or `\r`),
/// or 0 when `bytes[i]` does not start one. Same definition as
/// `source.Line`.
fn lineEndingLen(bytes: []const u8, i: usize) usize {
    return switch (bytes[i]) {
        '\n' => 1,
        '\r' => if (i + 1 < bytes.len and bytes[i + 1] == '\n') 2 else 1,
        else => 0,
    };
}

/// §6.8 URI autolink: `<` + scheme (2–32 chars) + `:` + content (no ASCII
/// control, space, `<`, `>`) + `>`. `pos` is at the `<`; `end` bounds the
/// scan (a line end, since content cannot contain line endings). Returns
/// null when the bytes do not form a URI autolink.
fn scanUriAutolink(bytes: []const u8, pos: usize, end: usize) ?AutolinkScan {
    const start = pos + 1;
    var p = start;
    // Scheme: first char an ASCII letter, then scheme chars, 2..32 total.
    if (p >= end or !isAsciiLetter(bytes[p])) return null;
    var scheme_len: usize = 1;
    p += 1;
    while (p < end and isSchemeChar(bytes[p]) and scheme_len < 32) : (p += 1) {
        scheme_len += 1;
    }
    // The scheme ends at the `:` and must be 2..32 chars (`<m:abc>` is
    // not an autolink); a 33+ char run is not a scheme.
    if (scheme_len < 2 or scheme_len > 32 or p >= end or bytes[p] != ':') return null;
    const content_start = p + 1;
    var q = content_start;
    while (q < end) : (q += 1) {
        const b = bytes[q];
        if (b == '>') {
            // The label/href is the *whole* text between the angle
            // brackets — scheme, colon, and content.
            return .{
                .span = .{ .start = @intCast(pos), .end = @intCast(q + 1) },
                .content = .{ .start = @intCast(start), .end = @intCast(q) },
                .is_email = false,
            };
        }
        // ASCII control, space, and `<` are forbidden in the content.
        if (b <= 0x20 or b == 0x7F or b == '<') return null;
    }
    return null;
}

/// §6.8 email autolink: `<` + email + `>`, where the email matches the
/// non-normative HTML5 regex (anchored). `pos` is at the `<`; `end` bounds
/// the scan. Returns null when the bytes do not form an email autolink.
fn scanEmailAutolink(bytes: []const u8, pos: usize, end: usize) ?AutolinkScan {
    const start = pos + 1;
    var p = start;
    // Local part: one or more local-part characters.
    if (p >= end or !isEmailLocalChar(bytes[p])) return null;
    p += 1;
    while (p < end and isEmailLocalChar(bytes[p])) : (p += 1) {}
    if (p >= end or bytes[p] != '@') return null;
    p += 1;
    // Domain: one or more dot-separated labels. Each label is
    // `[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?`: a first alphanumeric,
    // then a middle run of up to 61 alphanumerics or hyphens, then one
    // alphanumeric. The label starts and ends alphanumeric, and the whole
    // label is at most 63 chars (1 + 61 + 1). The regex is greedy, so a
    // maximal [alnum-] run after the first char is a valid label iff its
    // length is at most 62 and it ends in an alphanumeric.
    var labels: usize = 0;
    while (true) {
        if (p >= end or !isAsciiLetter(bytes[p]) and !(bytes[p] >= '0' and bytes[p] <= '9')) return null;
        p += 1;
        var run: usize = 0;
        var last_alnum = true;
        while (p < end and isEmailDomainChar(bytes[p])) : (p += 1) {
            run += 1;
            const alnum = isAsciiLetter(bytes[p]) or (bytes[p] >= '0' and bytes[p] <= '9');
            last_alnum = alnum;
            if (run > 62) return null; // middle run exceeds 61 + final char
        }
        if (!last_alnum) return null; // label must end in an alphanumeric
        labels += 1;
        if (p >= end) return null;
        if (bytes[p] == '>') {
            if (labels == 0) return null;
            return .{
                .span = .{ .start = @intCast(pos), .end = @intCast(p + 1) },
                .content = .{ .start = @intCast(start), .end = @intCast(p) },
                .is_email = true,
            };
        }
        if (bytes[p] != '.') return null;
        p += 1;
    }
}

/// Tries to recognize an autolink starting at the `<` at `pos` (§6.8): URI
/// first, then email. Returns null when neither matches (the `<` stays
/// literal text).
fn scanAutolink(bytes: []const u8, pos: usize, end: usize) ?AutolinkScan {
    return scanUriAutolink(bytes, pos, end) orelse scanEmailAutolink(bytes, pos, end);
}

fn scanLine(
    doc: *document.Document,
    items: *std.ArrayList(InlineItem),
    raw: source.Span,
    emit: source.Span,
    constructs: []const Construct,
    exclude: *u32,
    options: Options,
) ParseError!void {
    const bytes = doc.src.bytes;
    var i = raw.start;
    var run_start = raw.start;
    var ci: usize = 0;
    // Skip constructs that closed before this line, or that an autolink
    // consumed on an earlier line (first-come: they are dead for the rest
    // of the paragraph — docs/RAW-HTML.md §2).
    while (ci < constructs.len and
        (constructs[ci].span.end <= raw.start or constructs[ci].span.start < exclude.*))
    {
        ci += 1;
    }
    while (i < raw.end) : (i += 1) {
        // Inside a construct that opened on an earlier line: skip to its
        // end; the item was appended when the construct opened.
        if (ci < constructs.len and i > constructs[ci].span.start and i < constructs[ci].span.end) {
            i = constructs[ci].span.end - 1;
            run_start = constructs[ci].span.end;
            ci += 1;
            continue;
        }
        // At a construct opening: flush the preceding text, append the
        // construct item, skip the whole construct.
        if (ci < constructs.len and i == constructs[ci].span.start) {
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
            switch (constructs[ci].kind) {
                .code_span => try items.append(doc.allocator(), .{
                    .code_span = .{ .span = constructs[ci].span, .content = constructs[ci].content },
                }),
                .html_tag => try items.append(doc.allocator(), .{
                    .raw_html = .{ .span = constructs[ci].span },
                }),
            }
            i = constructs[ci].span.end - 1;
            run_start = constructs[ci].span.end;
            ci += 1;
            continue;
        }
        const b = bytes[i];
        if (b == '!' and !isEscaped(bytes, i) and
            i + 1 < raw.end and bytes[i + 1] == '[' and !isEscaped(bytes, i + 1))
        {
            // `![` with both characters unescaped is an image opener (§6.7):
            // a bracket item spanning both bytes. An escaped `!` or `[` at
            // the boundary is literal text (`\![foo]` is an escaped `!`;
            // `!\[foo]` has an escaped `[` — neither opens an image).
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
            try items.append(doc.allocator(), .{
                .bracket = .{ .ch = '!', .span = .{ .start = @intCast(i), .end = @intCast(i + 2) } },
            });
            run_start = i + 2;
            i += 1; // the loop increments past the `[`
        } else if (b == '[' or b == ']') {
            if (isEscaped(bytes, i)) continue; // literal text, not a bracket
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
            try items.append(doc.allocator(), .{
                .bracket = .{ .ch = b, .span = .{ .start = @intCast(i), .end = @intCast(i + 1) } },
            });
            run_start = i + 1;
        } else if (b == '*' or b == '_') {
            if (isEscaped(bytes, i)) continue; // literal text, not a delimiter
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);

            var e = i + 1;
            while (e < raw.end and bytes[e] == b and !isEscaped(bytes, e)) : (e += 1) {}
            const span = source.Span{ .start = @intCast(i), .end = @intCast(e) };
            try items.append(doc.allocator(), .{
                .delimiter = classifyRun(bytes, span, raw),
            });
            i = e - 1; // loop increments past the run
            run_start = e;
        } else if (b == '~' and options.strikethrough) {
            if (isEscaped(bytes, i)) continue; // literal text, not a delimiter
            // GFM strikethrough: only a run of exactly two tildes is a
            // delimiter (GFM spec §6.5); runs of one or three-plus tildes
            // stay literal text. A non-delimiter run is consumed whole so
            // its middle cannot re-scan as a two-tilde delimiter.
            var e = i + 1;
            while (e < raw.end and bytes[e] == '~' and !isEscaped(bytes, e)) : (e += 1) {}
            if (e - i != 2) {
                i = e - 1; // loop increments past the whole run
                continue;
            }
            try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
            const span = source.Span{ .start = @intCast(i), .end = @intCast(e) };
            try items.append(doc.allocator(), .{
                .delimiter = classifyRun(bytes, span, raw),
            });
            i = e - 1; // loop increments past the run
            run_start = e;
        } else if (b == '<' and !isEscaped(bytes, i)) {
            // §6.8 autolink: `<scheme:...>` or `<user@host>`. The scan is
            // per-line and the content excludes line endings, so scanning
            // within `raw` is complete; the autolink item is opaque to the
            // delimiter stack and link discovery (docs/AUTOLINKS.md §2). A
            // `(` after a failed match is literal text; an escaped `\<` is
            // literal (handled above by `!isEscaped`).
            if (scanAutolink(bytes, i, raw.end)) |al| {
                try appendTextItem(doc, items, .{ .start = run_start, .end = i }, emit);
                try items.append(doc.allocator(), .{ .autolink = al });
                i = al.span.end - 1; // loop increments past the `>`
                run_start = al.span.end;
                // An autolink that started before a backtick run wins the
                // first-come race: skip any construct whose opening lies
                // inside the consumed `<...>`, and record the exclusion so
                // later lines keep them dead (their closers cannot revive
                // them — docs/RAW-HTML.md §2).
                while (ci < constructs.len and constructs[ci].span.start < al.span.end) ci += 1;
                if (al.span.end > exclude.*) exclude.* = al.span.end;
            }
            // No match: fall through; the `<` is literal text.
        }
    }
    try appendTextItem(doc, items, .{ .start = run_start, .end = raw.end }, emit);
}

fn appendTextItem(
    doc: *document.Document,
    items: *std.ArrayList(InlineItem),
    span: source.Span,
    emit: source.Span,
) ParseError!void {
    const start = @max(span.start, emit.start);
    const end = @min(span.end, emit.end);
    if (start >= end) return;
    try items.append(doc.allocator(), .{
        .text = .{ .start = @intCast(start), .end = @intCast(end) },
    });
}

/// Classifies a delimiter run per §6.2. The character *after* the run and
/// the character *before* it are decoded as code points; the beginning and
/// end of the line count as Unicode whitespace. A backslash directly after a
/// run is either a literal backslash or the escape marker of an escaped
/// ASCII-punctuation character — in both cases the following character is
/// punctuation, so the raw byte decode is exactly the rendered-stream
/// reading (see docs/INLINE-PARSING.md §16.1).
fn classifyRun(bytes: []const u8, span: source.Span, line: source.Span) DelimiterRun {
    const prev_char = if (span.start == line.start) null else unicode.decodePrev(bytes, span.start);
    const next_char = if (span.end == line.end) null else unicode.decode(bytes, span.end);

    const prev_ws = span.start == line.start or (prev_char != null and unicode.isWhitespace(prev_char.?));
    const prev_punct = prev_char != null and unicode.isPunctuation(prev_char.?);
    const next_ws = span.end == line.end or (next_char != null and unicode.isWhitespace(next_char.?));
    const next_punct = next_char != null and unicode.isPunctuation(next_char.?);

    // §6.2 flanking definitions.
    const left_flanking = !next_ws and (!next_punct or (next_punct and (prev_ws or prev_punct)));
    const right_flanking = !prev_ws and (!prev_punct or (prev_punct and (next_ws or next_punct)));

    // Rules 1–8. For `*` (and GFM strikethrough `~`), opening/closing needs
    // only the corresponding flanking; for `_`, the stricter intraword
    // rules with the punctuation-adjacent (b) clauses.
    const ch = bytes[span.start];
    const can_open = left_flanking and
        (ch != '_' or !right_flanking or (right_flanking and prev_punct));
    const can_close = right_flanking and
        (ch != '_' or !left_flanking or (left_flanking and next_punct));

    return .{
        .ch = ch,
        .span = span,
        .can_open = can_open,
        .can_close = can_close,
    };
}

// ---------------------------------------------------------------------------
// Inline pass: delimiter stack matching.
// ---------------------------------------------------------------------------

/// One emphasis/strong match discovered by the match phase. Segment spans are
/// the *consumed* byte ranges of each run: the opener's back and the closer's
/// front (the ends adjacent to the matched content); leftover bytes are
/// literal text and lie outside them.
const Match = struct {
    kind: Kind,
    opener_item: usize,
    closer_item: usize,
    opener_seg: source.Span,
    closer_seg: source.Span,

    const Kind = enum { em, strong, strikethrough };
};

/// `openers_bottom` table: for each (delimiter character, closer length
/// mod 3), the number of entries at the bottom of the delimiter stack that
/// can never match a closer of that key. Raising it is what keeps matching
/// amortized linear (docs/INLINE-PARSING.md §8.5).
///
/// Deliberate chosen behavior: a closer's key is fixed at its *first*
/// processing (the original run length mod 3) and applies to leftover
/// re-loops too, and bottoms are shared across closer kinds. This reproduces
/// the reference behavior on inputs like `*****Hello*world****` (see
/// docs/FEATURE-MATRIX.md, "emphasis" row) and every verified spec example.
const Bottoms = struct {
    inner: [3][3]usize = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } },

    fn idx(ch: u8) usize {
        return if (ch == '*') 0 else if (ch == '~') 2 else 1;
    }

    fn get(self: *const Bottoms, ch: u8, m: usize) usize {
        return self.inner[idx(ch)][m];
    }

    fn set(self: *Bottoms, ch: u8, m: usize, v: usize) void {
        self.inner[idx(ch)][m] = v;
    }

    /// After popping the stack down to `keep` entries, dead entries above
    /// `keep` are gone; clamp every bottom so it never points past the
    /// stack.
    fn clampOnPop(self: *Bottoms, keep: usize) void {
        for (0..2) |i| {
            for (0..3) |j| {
                self.inner[i][j] = @min(self.inner[i][j], keep);
            }
        }
    }
};

/// Processes one delimiter item as a potential closer (and then, for any
/// leftover, as a potential opener). Runs left to right; `items` is not
/// resized during matching.
fn processDelimiter(
    doc: *document.Document,
    items: []InlineItem,
    stack: *std.ArrayList(usize),
    bottoms: *Bottoms,
    matches: *std.ArrayList(Match),
    c_idx: usize,
) ParseError!void {
    const c = &items[c_idx].delimiter;
    if (!c.can_close) {
        if (c.can_open) try stack.append(doc.allocator(), c_idx);
        return;
    }

    // The closer's key (length mod 3) is fixed at first processing and
    // applies to leftover re-loops (see Bottoms comment).
    const m: usize = c.len() % 3;

    while (c.len() > 0 and c.can_close) {
        const bottom = bottoms.get(c.ch, m);
        var j = stack.items.len;
        var matched = false;
        while (j > bottom) {
            j -= 1;
            const o_idx = stack.items[j];
            const o = &items[o_idx].delimiter;
            if (o.ch != c.ch) continue;
            if (!o.can_open or (o.ch != '~' and !mod3Allowed(o, c))) continue;

            // Consume from the opener's back and the closer's front (the
            // ends adjacent to the matched content). Strong pairs take two
            // delimiters from each side; GFM strikethrough pairs take the
            // whole two-tilde run from each side.
            const kind: Match.Kind = if (o.ch == '~') .strikethrough else if (o.len() >= 2 and c.len() >= 2) .strong else .em;
            const take: u32 = if (kind == .strikethrough) 2 else if (kind == .strong) 2 else 1;
            const o_seg = source.Span{
                .start = o.span.end - o.back_used - take,
                .end = o.span.end - o.back_used,
            };
            const c_seg = source.Span{
                .start = c.span.start + c.front_used,
                .end = c.span.start + c.front_used + take,
            };
            o.back_used += take;
            c.front_used += take;
            try matches.append(doc.allocator(), .{
                .kind = kind,
                .opener_item = o_idx,
                .closer_item = c_idx,
                .opener_seg = o_seg,
                .closer_seg = c_seg,
            });

            // Everything at or above the opener is consumed: the opener
            // itself unless it still has delimiters left, and all trapped
            // openers above it (they lie inside the matched span).
            const keep = j + @intFromBool(o.len() > 0);
            bottoms.clampOnPop(keep);
            stack.shrinkRetainingCapacity(keep);
            matched = true;
            break;
        }
        if (!matched) {
            // Every opener examined is dead for this key.
            bottoms.set(c.ch, m, stack.items.len);
            break;
        }
    }

    if (c.len() > 0 and c.can_open) try stack.append(doc.allocator(), c_idx);
}

/// Rule 9/10 mod-3 test. Applies only when one of the two runs can both open
/// and close; the constraint is identical for emphasis and strong emphasis.
fn mod3Allowed(o: *const DelimiterRun, c: *const DelimiterRun) bool {
    if (!(o.can_open and o.can_close) and !(c.can_open and c.can_close)) return true;
    if ((o.len() + c.len()) % 3 != 0) return true;
    return o.len() % 3 == 0 and c.len() % 3 == 0;
}

/// Runs the match phase over `items` (delimiter stack, rules 1–12),
/// returning the arena-allocated match list. Mutates only
/// `front_used`/`back_used` inside delimiter items; the item list itself
/// is stable, so it is safe to alias it into a mutable slice. Each inline
/// scope is matched exactly once: paragraph/heading items, link-text
/// children, and image-description children (the latter only so the
/// consumed delimiters are known when flattening to the alt string).
fn matchItems(doc: *document.Document, items: []const InlineItem) ParseError![]const Match {
    var stack = std.ArrayList(usize).empty;
    var bottoms = Bottoms{};
    var matches = std.ArrayList(Match).empty;

    const mutable = @constCast(items);
    for (mutable, 0..) |item, i| {
        if (item != .delimiter) continue;
        try processDelimiter(doc, mutable, &stack, &bottoms, &matches, i);
    }
    return matches.items;
}

/// Matches the item list as a fresh inline scope, then materializes
/// document nodes under `block`.
fn matchInlines(doc: *document.Document, block: *document.Node, items: []const InlineItem, options: Options) ParseError!void {
    try emitInlines(doc, block, @constCast(items), try matchItems(doc, items), options);
}

// ---------------------------------------------------------------------------
// Inline pass: emission.
// ---------------------------------------------------------------------------

/// Materializes document nodes from the matched item list. Frames (open
/// emphasis/strong nodes) are tracked on an explicit stack; nesting depth
/// never consumes the call stack.
fn emitInlines(
    doc: *document.Document,
    block: *document.Node,
    items: []const InlineItem,
    matches: []const Match,
    options: Options,
) ParseError!void {
    const n = items.len;
    const alloc = doc.allocator();

    // Bucket matches by opener item and by closer item (two counting passes,
    // so emission is linear in items + matches). `off[i]` starts as the
    // count of matches at item i, then becomes the start offset of item i's
    // bucket; `off[n]` is the total. In-place prefix sums: the count at
    // position i is consumed into the accumulator *after* the prefix is
    // written there, so the bucket for item i spans [off[i], off[i + 1]).
    const opener_off = try alloc.alloc(usize, n + 1);
    const closer_off = try alloc.alloc(usize, n + 1);
    @memset(opener_off, 0);
    @memset(closer_off, 0);
    for (matches) |m| {
        opener_off[m.opener_item] += 1;
        closer_off[m.closer_item] += 1;
    }
    var acc: usize = 0;
    for (0..n) |i| {
        const count = opener_off[i];
        opener_off[i] = acc;
        acc += count;
    }
    opener_off[n] = acc;
    acc = 0;
    for (0..n) |i| {
        const count = closer_off[i];
        closer_off[i] = acc;
        acc += count;
    }
    closer_off[n] = acc;
    const opener_idx = try alloc.alloc(usize, matches.len);
    const closer_idx = try alloc.alloc(usize, matches.len);
    {
        var cursor = try alloc.dupe(usize, opener_off[0..n]);
        for (matches, 0..) |m, k| {
            const i = m.opener_item;
            opener_idx[cursor[i]] = k;
            cursor[i] += 1;
        }
    }
    {
        var cursor = try alloc.dupe(usize, closer_off[0..n]);
        for (matches, 0..) |m, k| {
            const i = m.closer_item;
            closer_idx[cursor[i]] = k;
            cursor[i] += 1;
        }
    }

    var frames = std.ArrayList(*document.Node).empty;
    var current = block;

    for (items, 0..) |item, i| {
        switch (item) {
            .text => |span| try emitTextRuns(doc, current, span, options),
            .brk => |brk| {
                const node = try doc.createNode(
                    if (brk.kind == .hard) .hard_break else .soft_break,
                    brk.span,
                    .none,
                );
                try doc.appendChild(current, node);
            },
            .code_span => |cs| {
                const node = try doc.createNode(.code_span, cs.span, .{
                    .code_span = try normalizeCodeSpan(doc, cs.content),
                });
                try doc.appendChild(current, node);
            },
            .bracket => |br| try emitText(doc, current, br.span, options),
            .link => |lk| {
                // The link's text is a fresh inline scope: children are
                // matched with the `[` opener as stack_bottom (the spec's
                // "process emphasis" call), so they never see delimiters
                // outside the brackets — and they contain no links (see
                // discoverLinksAndImages).
                const node = try doc.createNode(.link, lk.span, .{
                    .link = .{
                        .href = try resolveEscapes(doc, lk.dest),
                        .title = if (lk.title) |ts| try resolveEscapes(doc, ts) else null,
                    },
                });
                try doc.appendChild(current, node);
                try matchInlines(doc, node, lk.children.items, options);
            },
            .image => |im| {
                // Leaf node (no children): the description is flattened to
                // the plain-string alt at parse time, per §6.7
                // (docs/IMAGES-PARSING.md §3). `src`/`title` resolve
                // escapes like a link's href/title.
                const node = try doc.createNode(.image, im.span, .{
                    .image = .{
                        .src = try resolveEscapes(doc, im.dest),
                        .alt = try flattenAlt(doc, im.children.items),
                        .title = if (im.title) |ts| try resolveEscapes(doc, ts) else null,
                    },
                });
                try doc.appendChild(current, node);
            },
            .raw_html => |h| {
                // Leaf node: the whole tag construct, rendered verbatim
                // from the source span (no payload; docs/RAW-HTML.md §3).
                const node = try doc.createNode(.raw_html, h.span, .none);
                try doc.appendChild(current, node);
            },
            .footnote => |fn_| {
                // Leaf node (extension): `[^label]` with a registered
                // definition. The label payload is a source slice; the
                // renderer numbers it in first-reference order.
                const node = try doc.createNode(.footnote_ref, fn_.span, .{
                    .footnote_ref = .{ .label = doc.text(fn_.label) },
                });
                try doc.appendChild(current, node);
            },
            .wikilink => |wk| {
                // Leaf node (extension): the trimmed target/label,
                // re-derived from the content span validated at discovery
                // (docs/WIKILINKS.md §4). Both payloads are source slices
                // — trimming narrowed the span, no copy. Resolution is a
                // renderer policy (`html.RenderOptions.wikilink_resolver`).
                const parts = splitWikilinkContent(doc.src.bytes, wk.content).?;
                const node = try doc.createNode(.wikilink, wk.span, .{
                    .wikilink = .{
                        .target = doc.text(parts.target),
                        .label = if (parts.label) |ls| doc.text(ls) else null,
                    },
                });
                try doc.appendChild(current, node);
            },
            .autolink => |al| {
                // Leaf node: the content between `<` and `>` becomes both
                // the label and the href (with `mailto:` prepended for
                // email autolinks). Backslash escapes are inert inside
                // autolinks (§6.5), but entity references are still
                // recognized (the reference implementation's
                // `cmark_clean_autolink`/`make_str_with_entities` decode
                // them); the payload is arena-owned because of the prefix
                // and the decoded copy (docs/AUTOLINKS.md §3).
                const content = try resolveEntities(doc, al.content);
                const href = if (al.is_email)
                    try std.fmt.allocPrint(doc.allocator(), "mailto:{s}", .{content})
                else
                    try doc.allocator().dupe(u8, content);
                const node = try doc.createNode(.autolink, al.span, .{
                    .autolink = .{
                        .href = href,
                        .label = try doc.allocator().dupe(u8, content),
                    },
                });
                try doc.appendChild(current, node);
            },
            .delimiter => |run| {
                const o_start = opener_off[i];
                const o_end = opener_off[i + 1];
                const c_start = closer_off[i];
                const c_end = closer_off[i + 1];

                // Leftover delimiters are the run's middle: consumed bytes
                // were taken from the front (as closer) and the back (as
                // opener). This is the source range [start + front_used,
                // end - back_used).
                const leftover = run.len();

                // Close frames for closer matches, innermost first. Matches
                // closing here are exactly the frames on top of the stack
                // (an opener trapped above a matched opener is consumed by
                // that match, never matched later), so the stack discipline
                // holds.
                if (c_end > c_start) {
                    const bucket = closer_idx[c_start..c_end];
                    std.mem.sort(usize, bucket, matches, closerLess);
                    for (bucket) |_| {
                        _ = frames.pop();
                        current = if (frames.items.len > 0)
                            frames.items[frames.items.len - 1]
                        else
                            block;
                    }
                }

                // Leftover delimiters are literal text. Emitted after the
                // frames they close (a closer's leftover sits inside the
                // byte range but outside the matched span, e.g. `*foo***`)
                // and before the frames they open (an opener's leftover
                // precedes its consumed bytes, e.g. `***foo**`).
                if (leftover > 0) {
                    try emitText(doc, current, .{
                        .start = run.span.start + run.front_used,
                        .end = run.span.end - run.back_used,
                    }, options);
                }

                // Open frames for opener matches, outermost first (smallest
                // consumed offset).
                if (o_end > o_start) {
                    const obucket = opener_idx[o_start..o_end];
                    std.mem.sort(usize, obucket, matches, openerLess);
                    for (obucket) |k| {
                        const m = matches[k];
                        const node = try doc.createNode(
                            switch (m.kind) {
                                .em => .emphasis,
                                .strong => .strong,
                                .strikethrough => .deleted,
                            },
                            .{ .start = m.opener_seg.start, .end = m.closer_seg.end },
                            .none,
                        );
                        try doc.appendChild(current, node);
                        try frames.append(doc.allocator(), node);
                        current = node;
                    }
                }
            },
        }
    }
}

/// Closer matches at one item close innermost-first: the frame opened most
/// recently (largest opener position) is on top.
fn closerLess(ctx: []const Match, a: usize, b: usize) bool {
    const ma = ctx[a];
    const mb = ctx[b];
    if (ma.opener_item != mb.opener_item) return ma.opener_item > mb.opener_item;
    return ma.opener_seg.start > mb.opener_seg.start;
}

/// Opener matches at one item open outermost-first: smallest consumed offset
/// first.
fn openerLess(ctx: []const Match, a: usize, b: usize) bool {
    const ma = ctx[a];
    const mb = ctx[b];
    return ma.opener_seg.start < mb.opener_seg.start;
}

/// Emits text nodes for the content range, resolving backslash escapes
/// (§2.4): a backslash before an ASCII punctuation character produces that
/// character literally (the backslash is consumed, so it is not covered by
/// any node's span); a backslash before anything else is a literal
/// backslash. Each escape splits the text into adjacent text nodes.
fn emitTextRuns(doc: *document.Document, parent: *document.Node, span: source.Span, options: Options) ParseError!void {
    if (span.isEmpty()) return;
    const bytes = doc.src.bytes;

    var i = span.start;
    var run_start = span.start;
    while (i < span.end) : (i += 1) {
        if (bytes[i] == '\\' and i + 1 < span.end and isAsciiPunctuation(bytes[i + 1])) {
            try emitText(doc, parent, .{ .start = run_start, .end = i }, options);
            try emitText(doc, parent, .{ .start = i + 1, .end = i + 2 }, options);
            i += 1;
            run_start = i + 1;
        }
    }
    try emitText(doc, parent, .{ .start = run_start, .end = span.end }, options);
}

/// §6.1 normalization of a code span's raw content: line endings become
/// spaces; if the result both begins and ends with a space (U+0020 — "Only
/// [spaces], and not unicode whitespace in general, are stripped") and does
/// not consist entirely of spaces, one space is removed from the front and
/// back. The result is copied into the document arena: it is the one text
/// payload not borrowed from the source (docs/DOCUMENT-MODEL.md).
fn normalizeCodeSpan(doc: *document.Document, content: source.Span) ParseError![]const u8 {
    const bytes = doc.src.bytes;
    if (content.isEmpty()) return "";

    // Pass 1: normalized length (a line ending \n, \r\n, or \r is one
    // space).
    var n: usize = 0;
    var i = content.start;
    while (i < content.end) : (i += 1) {
        if (bytes[i] == '\r') {
            if (i + 1 < content.end and bytes[i + 1] == '\n') i += 1;
        }
        n += 1;
    }

    const buf = try doc.allocator().alloc(u8, n);
    var k: usize = 0;
    i = content.start;
    while (i < content.end) : (i += 1) {
        const b = bytes[i];
        if (b == '\n' or b == '\r') {
            if (b == '\r' and i + 1 < content.end and bytes[i + 1] == '\n') i += 1;
            buf[k] = ' ';
        } else {
            buf[k] = b;
        }
        k += 1;
    }

    if (n >= 2 and buf[0] == ' ' and buf[n - 1] == ' ' and !allSpaces(buf)) {
        return buf[1 .. n - 1];
    }
    return buf;
}

fn allSpaces(s: []const u8) bool {
    for (s) |b| {
        if (b != ' ') return false;
    }
    return true;
}

/// Resolves §2.5 entity references and §2.4 backslash escapes into an
/// arena-owned copy. Entities are decoded first (the reference
/// implementation's order: `houdini_unescape_html_f` then backslash
/// unescaping), then `\X` where X is ASCII punctuation becomes the literal
/// character X (the backslash is dropped); a backslash before anything
/// else is a literal backslash. Used for link destinations and titles
/// (§6.6: "with backslash-escapes in effect as described above" — §2.5
/// recognizes references "in any context besides code spans or code
/// blocks, including URLs, link titles, and fenced code info strings"),
/// image src/titles, fenced info strings, and alt flattening. Payloads
/// cannot borrow the source because references are consumed. Line endings
/// are kept verbatim (titles may span lines).
fn resolveEscapes(doc: *document.Document, span: source.Span) ParseError![]const u8 {
    const decoded = try resolveEntities(doc, span);
    var n: usize = 0;
    var i: usize = 0;
    while (i < decoded.len) : (i += 1) {
        if (decoded[i] == '\\' and i + 1 < decoded.len and isAsciiPunctuation(decoded[i + 1])) {
            i += 1;
        }
        n += 1;
    }

    const buf = try doc.allocator().alloc(u8, n);
    var k: usize = 0;
    i = 0;
    while (i < decoded.len) : (i += 1) {
        if (decoded[i] == '\\' and i + 1 < decoded.len and isAsciiPunctuation(decoded[i + 1])) {
            buf[k] = decoded[i + 1];
            i += 1;
        } else {
            buf[k] = decoded[i];
        }
        k += 1;
    }
    return buf;
}

/// Resolves §2.5 entity and numeric character references in a span into an
/// arena-owned copy, or returns the borrowed source span when the span
/// contains none. The common case (no `&` or no valid reference) borrows;
/// only a span containing a reference allocates.
fn resolveEntities(doc: *document.Document, span: source.Span) ParseError![]const u8 {
    const bytes = doc.src.bytes;
    var i = span.start;
    while (i < span.end) : (i += 1) {
        if (bytes[i] != '&') continue;
        if (entities.decodeAt(bytes, i) == null) continue;
        // A reference decodes here: build the arena copy from the start.
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(doc.allocator());
        var run_start = span.start;
        var j = span.start;
        while (j < span.end) : (j += 1) {
            if (bytes[j] == '&') {
                if (entities.decodeAt(bytes, j)) |dec| {
                    try buf.appendSlice(doc.allocator(), bytes[run_start..j]);
                    try buf.appendSlice(doc.allocator(), dec.bytes[0..dec.len]);
                    j = @intCast(dec.next - 1);
                    run_start = j + 1;
                }
            }
        }
        try buf.appendSlice(doc.allocator(), bytes[run_start..span.end]);
        return doc.allocator().dupe(u8, buf.items);
    }
    return bytes[span.start..span.end];
}

fn emitText(doc: *document.Document, parent: *document.Node, span: source.Span, options: Options) ParseError!void {
    if (span.isEmpty()) return;
    // Contiguous text in the same parent merges into one node: scanning
    // artifacts (item boundaries, leftover delimiters) must not fragment
    // the normalized model. The merged span covers adjacent source bytes,
    // so the borrowed text payload is exact.
    //
    // Escape splits are the one deliberate exception: a node whose first
    // byte is a backslash-escaped character never merges with the text
    // after it, so the escaped byte stays its own node and the renderer's
    // entity decoding remains escape-aware (`\&ouml;` must render
    // `&amp;ouml;`, never decode the reference the backslash protects).
    // The same test also exempts the escaped byte from smartypants: a
    // backslash-escaped `\"` or `\'` renders the literal straight
    // character (docs/SMARTY.md §3).
    const escaped = span.start > 0 and doc.src.bytes[span.start - 1] == '\\';
    if (parent.children.items.len > 0) {
        const last = parent.children.items[parent.children.items.len - 1];
        if (last.tag == .text and last.span.end == span.start and
            !(last.span.start > 0 and doc.src.bytes[last.span.start - 1] == '\\'))
        {
            last.span.end = span.end;
            last.data.text = if (options.smartypants and !escaped)
                try typography.replace(doc, last.span, false)
            else
                doc.text(last.span);
            return;
        }
    }
    const payload = if (options.smartypants and !escaped)
        try typography.replace(doc, span, false)
    else
        doc.text(span);
    const node = try doc.createNode(.text, span, .{ .text = payload });
    try doc.appendChild(parent, node);
}

// ---------------------------------------------------------------------------
// Inline pass: alt flattening (images, §6.7).
// ---------------------------------------------------------------------------

/// One scope frame of the alt-flattening work stack: an inline scope's
/// items plus the next item index. Emphasis matching for a scope runs when
/// the frame is pushed (it mutates delimiter items' consumed counters, so
/// the walk itself needs no match list).
const FlattenScope = struct {
    items: []const InlineItem,
    i: usize,
};

/// Flattens an image description to its plain string content (the `alt`
/// attribute), per §6.7: "only the plain string content of the image
/// description be used ... without formatting" (docs/IMAGES-PARSING.md
/// §3). Each scope (the description itself, and the text of any link or
/// nested image inside it) is first matched as a fresh inline scope
/// (delimiter stack, rules 1–12), then walked in document order: text and
/// code-span content contribute directly (escapes resolved, backticks
/// dropped), consumed delimiters contribute nothing, leftover delimiters
/// and unconsumed brackets contribute their literal bytes, soft/hard
/// breaks contribute `\n`, and link and nested-image items contribute
/// their own flattened children. Nested scopes are processed on an
/// explicit work stack, so hostile nesting cannot overflow the call
/// stack. Returns an arena-owned copy (like `code_span`/`link` payloads,
/// the alt cannot be a source slice).
fn flattenAlt(doc: *document.Document, items: []const InlineItem) ParseError![]const u8 {
    var buf = std.ArrayList(u8).empty;
    var work = std.ArrayList(FlattenScope).empty;
    defer work.deinit(doc.allocator());

    _ = try matchItems(doc, items); // consumed delimiters are known to the walk
    try work.append(doc.allocator(), .{ .items = items, .i = 0 });
    while (work.items.len > 0) {
        const top = work.items.len - 1;
        const f = &work.items[top];
        if (f.i >= f.items.len) {
            work.shrinkRetainingCapacity(top);
            continue;
        }
        const item = f.items[f.i];
        f.i += 1;
        switch (item) {
            .text => |span| try buf.appendSlice(doc.allocator(), try resolveEscapes(doc, span)),
            .code_span => |cs| try buf.appendSlice(doc.allocator(), try normalizeCodeSpan(doc, cs.content)),
            .brk => try buf.append(doc.allocator(), '\n'),
            .delimiter => |run| try buf.appendSlice(doc.allocator(), doc.src.bytes[run.span.start + run.front_used .. run.span.end - run.back_used]),
            .bracket => |br| try buf.appendSlice(doc.allocator(), doc.src.bytes[br.span.start..br.span.end]),
            .link => |lk| {
                _ = try matchItems(doc, lk.children.items);
                try work.append(doc.allocator(), .{ .items = lk.children.items, .i = 0 });
            },
            .image => |im| {
                _ = try matchItems(doc, im.children.items);
                try work.append(doc.allocator(), .{ .items = im.children.items, .i = 0 });
            },
            .autolink => |al| try buf.appendSlice(doc.allocator(), doc.src.bytes[al.content.start..al.content.end]),
            .raw_html => |h| try buf.appendSlice(doc.allocator(), doc.src.bytes[h.span.start..h.span.end]),
            .footnote => {}, // a footnote ref contributes no plain text to an alt
            // A wikilink never reaches a description (demoted to literal
            // text when a link/image forms); the case is exhaustive and
            // contributes the raw bytes defensively.
            .wikilink => |wk| try buf.appendSlice(doc.allocator(), doc.src.bytes[wk.content.start..wk.content.end]),
        }
    }
    return buf.toOwnedSlice(doc.allocator());
}

// ---------------------------------------------------------------------------
// Character classes and helpers.
// ---------------------------------------------------------------------------

/// §2.1: ASCII punctuation is U+0021–2F, U+003A–0040, U+005B–0060,
/// U+007B–007E — the only characters backslash escapes may escape.
fn isAsciiPunctuation(b: u8) bool {
    return switch (b) {
        '!'...'/' => true,
        ':'...'@' => true,
        '['...'`' => true,
        '{'...'~' => true,
        else => false,
    };
}

/// True if the byte at index `i` is preceded by an odd number of backslashes
/// (i.e., that backslash escapes it). Safe at `i == 0`. A line terminator is
/// never a backslash, so escape parity never leaks across lines.
fn isEscaped(bytes: []const u8, i: usize) bool {
    var n: usize = 0;
    var j = i;
    while (j > 0 and bytes[j - 1] == '\\') : (j -= 1) {
        n += 1;
    }
    return n % 2 == 1;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "markdown: paragraphs, soft breaks, ATX headings end to end" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "Foo bar\n# baz\nBar foo", .markdown, .{});
    defer result.deinit();

    try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    try testing.expectEqual(document.Tag.heading, result.document.root.children.items[1].tag);
    try testing.expectEqual(@as(u8, 1), result.document.root.children.items[1].data.heading.level);
    try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[2].tag);
}

test "markdown: GFM tables parse into table/row/cell nodes" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "| a | b |\n| :- | -: |\n| 1 | 2 |\n| 3 |\n",
        .markdown,
        .{},
    );
    defer result.deinit();

    const table = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.table, table.tag);
    // Alignment from the delimiter row: left, right.
    try testing.expectEqual(@as(usize, 2), table.data.table.alignment.len);
    try testing.expectEqual(document.TableAlign.left, table.data.table.alignment[0]);
    try testing.expectEqual(document.TableAlign.right, table.data.table.alignment[1]);
    // Three rows: header + two body rows (the second body row is padded).
    try testing.expectEqual(@as(usize, 3), table.children.items.len);
    const header = table.children.items[0];
    try testing.expectEqual(document.Tag.table_row, header.tag);
    try testing.expectEqual(@as(usize, 2), header.children.items.len);
    try testing.expectEqual(document.Tag.table_cell, header.children.items[0].tag);
    try testing.expect(header.children.items[0].data.table_cell.header);
    try testing.expectEqual(document.TableAlign.left, header.children.items[0].data.table_cell.alignment);
    const body = table.children.items[2];
    try testing.expect(!body.children.items[0].data.table_cell.header);
    // A short body row is padded with an empty cell; header cells have
    // inline text children.
    try testing.expectEqual(@as(usize, 2), body.children.items.len);
    try testing.expectEqualStrings("3", body.children.items[0].children.items[0].data.text);
    try testing.expectEqual(@as(usize, 0), body.children.items[1].children.items.len);
    try testing.expectEqualStrings("a", header.children.items[0].children.items[0].data.text);
}

test "markdown: GFM tables consume escaped pipes and stay paragraphs on mismatch" {
    const oliver = @import("oliver.zig");

    // `\|` is an escaped pipe: the cell splitter keeps it out of the
    // separator set, and a code span inside the cell drops the backslash
    // (GFM §4.10 example: `` `\|` `` renders <code>|</code>).
    {
        var result = try oliver.parse(testing.allocator, "| b `\\|` az |\n| --------- |\n", .markdown, .{});
        defer result.deinit();
        const table = result.document.root.children.items[0];
        const cell = table.children.items[0].children.items[0];
        // Children: text "b ", the code span, text " az".
        try testing.expectEqual(@as(usize, 3), cell.children.items.len);
        const code = cell.children.items[1];
        try testing.expectEqual(document.Tag.code_span, code.tag);
        try testing.expectEqualStrings("|", code.data.code_span);
    }
    // Header/delimiter column mismatch: "a table will not be recognized".
    {
        var result = try oliver.parse(testing.allocator, "| abc | def |\n| --- |\n| bar |\n", .markdown, .{});
        defer result.deinit();
        try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
    // A pipe-less header line can never be a table header: `abc` followed
    // by a one-column delimiter stays a paragraph.
    {
        var result = try oliver.parse(testing.allocator, "abc\n| --- |\n", .markdown, .{});
        defer result.deinit();
        try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    }
}

test "markdown: heading recognition edge cases" {
    const oliver = @import("oliver.zig");

    // Tab after the opening # is accepted whitespace (spec §2.2 example 10).
    {
        var result = try oliver.parse(testing.allocator, "#\tfoo", .markdown, .{});
        defer result.deinit();
        const h = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.heading, h.tag);
        try testing.expectEqualStrings("foo", h.children.items[0].data.text);
    }
    // A leading tab is four columns of indentation (§2.1): the line is an
    // indented code block, not a heading (§4.4).
    {
        var result = try oliver.parse(testing.allocator, "\t# foo", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("# foo\n", code.data.code_block.content);
    }
}

test "markdown: source spans" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "# hello", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqual(source.Span{ .start = 0, .end = 7 }, h.span);
    const t = h.children.items[0];
    try testing.expectEqual(source.Span{ .start = 2, .end = 7 }, t.span);
}

test "markdown: fenced code exposes normalized payload and exact span" {
    const oliver = @import("oliver.zig");
    const input = "  ``` zig\\+lang extra\r\n  <tag>\r x\n   ````";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const code = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.code_block, code.tag);
    try testing.expectEqual(source.Span{ .start = 0, .end = @as(u32, @intCast(input.len)) }, code.span);
    try testing.expectEqual(@as(usize, 0), code.children.items.len);
    try testing.expectEqualStrings("<tag>\nx\n", code.data.code_block.content);
    try testing.expectEqualStrings("zig+lang extra", code.data.code_block.info.?);
}

test "markdown: unclosed fences end at their containing block" {
    const oliver = @import("oliver.zig");
    const input = "> ```\n> aaa\n\nbbb\n\n- ~~~ lang\n  <x>\n  ~~~";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const root = result.document.root;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);

    const quote_code = root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.code_block, quote_code.tag);
    try testing.expectEqualStrings("aaa\n", quote_code.data.code_block.content);
    try testing.expectEqual(@as(?[]const u8, null), quote_code.data.code_block.info);

    try testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    const list_code = root.children.items[2].children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.code_block, list_code.tag);
    try testing.expectEqualStrings("<x>\n", list_code.data.code_block.content);
    try testing.expectEqualStrings("lang", list_code.data.code_block.info.?);
}

test "markdown: fenced blanks preserve excess list indentation without ending a blank-start item" {
    const oliver = @import("oliver.zig");
    const input = "-\n  ```\n    \n\n  more\n  ```";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const list = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.list, list.tag);
    const item = list.children.items[0];
    try testing.expectEqual(@as(usize, 1), item.children.items.len);
    const code = item.children.items[0];
    try testing.expectEqual(document.Tag.code_block, code.tag);
    // Two of the four spaces belong to the list item. A wholly unindented
    // blank also remains literal content and does not make the item inert.
    try testing.expectEqualStrings("  \n\nmore\n", code.data.code_block.content);
}

test "markdown: tabs expand to tab stops for block structure, literal in content" {
    const oliver = @import("oliver.zig");

    // §2.1 example 1/2: a leading tab (or spaces plus a tab) is four
    // columns of indentation; internal tabs stay literal bytes.
    {
        var result = try oliver.parse(testing.allocator, "\tfoo\tbaz\t\tbim", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("foo\tbaz\t\tbim\n", code.data.code_block.content);
    }
    {
        var result = try oliver.parse(testing.allocator, "  \tfoo\tbaz\t\tbim", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("foo\tbaz\t\tbim\n", code.data.code_block.content);
    }
    // §2.1 example 8: continuation lines may use a tab as their four
    // columns of indentation.
    {
        var result = try oliver.parse(testing.allocator, "    foo\n\tbar", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("foo\nbar\n", code.data.code_block.content);
    }
    // §2.1 example 3: excess indentation is preserved literally.
    {
        var result = try oliver.parse(testing.allocator, "    a\ta\n    ὐ\ta", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("a\ta\nὐ\ta\n", code.data.code_block.content);
    }
}

test "markdown: tabs in list item and block quote markers" {
    const oliver = @import("oliver.zig");

    // §2.1 example 4: a tab-indented continuation paragraph inside an item
    // (the tab is four columns, so it clears the two-column content indent).
    {
        var result = try oliver.parse(testing.allocator, "  - foo\n\n\tbar", .markdown, .{});
        defer result.deinit();
        const list = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.list, list.tag);
        const item = list.children.items[0];
        try testing.expectEqual(@as(usize, 2), item.children.items.len);
        try testing.expectEqual(document.Tag.paragraph, item.children.items[1].tag);
        try testing.expectEqualStrings("bar", item.children.items[1].children.items[0].data.text);
    }
    // §2.1 example 5: two tabs inside the item are 8 columns; after the
    // two-column content indent, six remain, so the code block strips four
    // and the leftover partial tab becomes two spaces.
    {
        var result = try oliver.parse(testing.allocator, "- foo\n\n\t\tbar", .markdown, .{});
        defer result.deinit();
        const list = result.document.root.children.items[0];
        const item = list.children.items[0];
        try testing.expectEqual(@as(usize, 2), item.children.items.len);
        const code = item.children.items[1];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("  bar\n", code.data.code_block.content);
    }
    // §2.1 example 6: the `>` marker's optional space may be a tab; one of
    // its three columns belongs to the delimiter, so `foo` sits six columns
    // into the quote and the code block starts with two spaces.
    {
        var result = try oliver.parse(testing.allocator, ">\t\tfoo", .markdown, .{});
        defer result.deinit();
        const quote = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.block_quote, quote.tag);
        const code = quote.children.items[0];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("  foo\n", code.data.code_block.content);
    }
    // §2.1 example 7: a tab after a list marker counts as whitespace; the
    // item's content indent is W+1 and the code block again starts with
    // two spaces.
    {
        var result = try oliver.parse(testing.allocator, "-\t\tfoo", .markdown, .{});
        defer result.deinit();
        const list = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.list, list.tag);
        const item = list.children.items[0];
        try testing.expectEqual(@as(usize, 1), item.children.items.len);
        const code = item.children.items[0];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("  foo\n", code.data.code_block.content);
    }
    // §2.1 example 9: tabs can supply the indentation of nested list items.
    {
        var result = try oliver.parse(testing.allocator, " - foo\n   - bar\n\t - baz", .markdown, .{});
        defer result.deinit();
        const list = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.list, list.tag);
        const item = list.children.items[0];
        // Item one: paragraph `foo` plus a nested list.
        try testing.expectEqual(@as(usize, 2), item.children.items.len);
        try testing.expectEqual(document.Tag.paragraph, item.children.items[0].tag);
        const nested = item.children.items[1];
        try testing.expectEqual(document.Tag.list, nested.tag);
        const nested_item = nested.children.items[0];
        try testing.expectEqual(@as(usize, 2), nested_item.children.items.len);
        try testing.expectEqual(document.Tag.paragraph, nested_item.children.items[0].tag);
        const inner = nested_item.children.items[1];
        try testing.expectEqual(document.Tag.list, inner.tag);
        const inner_item = inner.children.items[0];
        try testing.expectEqual(@as(usize, 1), inner_item.children.items.len);
        try testing.expectEqual(document.Tag.paragraph, inner_item.children.items[0].tag);
        try testing.expectEqualStrings("baz", inner_item.children.items[0].children.items[0].data.text);
    }
}

test "markdown: indented code chunks, trailing blanks, and interruption rules" {
    const oliver = @import("oliver.zig");

    // §4.4: three chunks separated by blank lines; blank lines with fewer
    // than four columns stay empty, and trailing blank lines are dropped.
    {
        var result = try oliver.parse(testing.allocator, "    chunk1\n\n    chunk2\n  \n \n \n    chunk3\n", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_block, code.tag);
        try testing.expectEqualStrings("chunk1\n\nchunk2\n\n\n\nchunk3\n", code.data.code_block.content);
    }
    // §4.4: excess indentation is included even on interior blank lines.
    {
        var result = try oliver.parse(testing.allocator, "    chunk1\n      \n      chunk2\n", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqualStrings("chunk1\n  \n  chunk2\n", code.data.code_block.content);
    }
    // §4.4: an indented code block cannot interrupt a paragraph.
    {
        var result = try oliver.parse(testing.allocator, "Foo\n    bar\n\n", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.paragraph, p.tag);
        try testing.expectEqualStrings("bar", p.children.items[p.children.items.len - 1].data.text);
    }
    // §4.4: a paragraph may follow immediately after indented code.
    {
        var result = try oliver.parse(testing.allocator, "    foo\nbar\n", .markdown, .{});
        defer result.deinit();
        const root = result.document.root;
        try testing.expectEqual(@as(usize, 2), root.children.items.len);
        try testing.expectEqual(document.Tag.code_block, root.children.items[0].tag);
        try testing.expectEqualStrings("foo\n", root.children.items[0].data.code_block.content);
        try testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    }
    // §4.4 example 110: content is literal, never parsed as Markdown.
    {
        var result = try oliver.parse(testing.allocator, "    <a/>\n    *hi*\n\n    - one\n", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqualStrings("<a/>\n*hi*\n\n- one\n", code.data.code_block.content);
    }
    // §4.4: more than four columns of indentation on the first line stay in
    // the content.
    {
        var result = try oliver.parse(testing.allocator, "        foo\n    bar\n", .markdown, .{});
        defer result.deinit();
        const code = result.document.root.children.items[0];
        try testing.expectEqualStrings("    foo\nbar\n", code.data.code_block.content);
    }
}

test "markdown: thematic breaks precede lists and interrupt paragraphs" {
    const oliver = @import("oliver.zig");
    const input = "Foo\n***\n- item\n  * * *";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const root = result.document.root;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, root.children.items[0].tag);
    try testing.expectEqual(document.Tag.thematic_break, root.children.items[1].tag);
    try testing.expectEqual(source.Span{ .start = 4, .end = 7 }, root.children.items[1].span);

    const list = root.children.items[2];
    try testing.expectEqual(document.Tag.list, list.tag);
    const item = list.children.items[0];
    try testing.expectEqual(@as(usize, 2), item.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, item.children.items[0].tag);
    try testing.expectEqual(document.Tag.thematic_break, item.children.items[1].tag);
    try testing.expectEqual(source.Span{ .start = 17, .end = 22 }, item.children.items[1].span);
}

test "markdown: Setext headings transform multiline paragraphs with exact spans" {
    const oliver = @import("oliver.zig");
    const input = "  Foo *bar\nbaz*  \n   ----  ";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const h = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.heading, h.tag);
    try testing.expectEqual(@as(u8, 2), h.data.heading.level);
    try testing.expectEqual(source.Span{ .start = 0, .end = @as(u32, @intCast(input.len)) }, h.span);
    try testing.expectEqual(document.Tag.text, h.children.items[0].tag);
    try testing.expectEqualStrings("Foo ", h.children.items[0].data.text);
    try testing.expectEqual(document.Tag.emphasis, h.children.items[1].tag);
    const em = h.children.items[1];
    try testing.expectEqual(@as(usize, 3), em.children.items.len);
    try testing.expectEqualStrings("bar", em.children.items[0].data.text);
    try testing.expectEqual(document.Tag.soft_break, em.children.items[1].tag);
    try testing.expectEqualStrings("baz", em.children.items[2].data.text);
}

test "markdown: Setext headings register leading definitions and preserve final backslashes" {
    const oliver = @import("oliver.zig");
    const input = "[foo]: /url\nBar\\\n===\n[foo]";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();

    const root = result.document.root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    const h = root.children.items[0];
    try testing.expectEqual(document.Tag.heading, h.tag);
    try testing.expectEqual(@as(u8, 1), h.data.heading.level);
    try testing.expectEqual(source.Span{ .start = 12, .end = 20 }, h.span);
    try testing.expectEqual(@as(usize, 1), h.children.items.len);
    try testing.expectEqualStrings("Bar\\", h.children.items[0].data.text);

    const p = root.children.items[1];
    try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
    try testing.expectEqualStrings("/url", p.children.items[0].data.link.href);
}

test "markdown: a final paragraph backslash remains literal" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "foo\\", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqualStrings("foo\\", p.children.items[0].data.text);
}

test "markdown: a final ATX backslash remains literal" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "### foo\\", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.heading, h.tag);
    try testing.expectEqual(@as(usize, 1), h.children.items.len);
    try testing.expectEqualStrings("foo\\", h.children.items[0].data.text);
}

test "markdown: escapes produce literal characters with precise spans" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "a\\*b", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // The escape marker is covered by no node. The escaped * (span {2,3})
    // stays its own node: it never merges with the following text, so the
    // renderer's entity decoding remains escape-aware (the boundary is
    // visible to the text pass).
    try testing.expectEqual(@as(usize, 3), p.children.items.len); // "a", "*", "b"
    try testing.expectEqualStrings("a", p.children.items[0].data.text);
    try testing.expectEqual(source.Span{ .start = 0, .end = 1 }, p.children.items[0].span);
    try testing.expectEqual(source.Span{ .start = 2, .end = 3 }, p.children.items[1].span);
    try testing.expectEqualStrings("*", p.children.items[1].data.text);
    try testing.expectEqual(source.Span{ .start = 3, .end = 4 }, p.children.items[2].span);
    try testing.expectEqualStrings("b", p.children.items[2].data.text);
}

test "markdown: hard breaks" {
    const oliver = @import("oliver.zig");

    // Two trailing spaces.
    {
        var result = try oliver.parse(testing.allocator, "foo  \nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
        try testing.expectEqualStrings("foo", p.children.items[0].data.text);
        // The trailing spaces are not covered by any text node.
        try testing.expectEqual(source.Span{ .start = 0, .end = 3 }, p.children.items[0].span);
    }
    // One trailing space is a soft break.
    {
        var result = try oliver.parse(testing.allocator, "foo \nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.soft_break, p.children.items[1].tag);
    }
    // An unescaped trailing backslash is a hard break.
    {
        var result = try oliver.parse(testing.allocator, "foo\\\nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
    }
    // An escaped backslash (`\\`) is literal text, not a hard break. The
    // escape splits into adjacent text nodes: "foo", then the literal `\`.
    {
        var result = try oliver.parse(testing.allocator, "foo\\\\\nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("foo", p.children.items[0].data.text);
        try testing.expectEqualStrings("\\", p.children.items[1].data.text);
        try testing.expectEqual(document.Tag.soft_break, p.children.items[2].tag);
    }
    // Trailing spaces on the last line are consumed without a break node.
    {
        var result = try oliver.parse(testing.allocator, "foo  ", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("foo", p.children.items[0].data.text);
    }
}

test "markdown: trailing tabs do not trigger hard breaks" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "foo\t\nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.soft_break, p.children.items[1].tag);
    }
    {
        // Two spaces before the tab still count.
        var result = try oliver.parse(testing.allocator, "foo  \t\nbar", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.hard_break, p.children.items[1].tag);
    }
}

test "markdown: ATX closing sequences ignore escaped hashes (spec example 76)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "### foo \\###\n## foo #\\##\n# foo \\#", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);
    try testing.expectEqualStrings("foo ###", try inlineText(&result.document, root.children.items[0]));
    try testing.expectEqualStrings("foo ###", try inlineText(&result.document, root.children.items[1]));
    try testing.expectEqualStrings("foo #", try inlineText(&result.document, root.children.items[2]));
}

test "markdown: escapes inside headings" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "# \\# not closing", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqualStrings("# not closing", try inlineText(&result.document, h));
}

// --- emphasis and strong emphasis (docs/INLINE-PARSING.md §6) ---

test "markdown: emphasis structure, spans, and literal fallback" {
    const oliver = @import("oliver.zig");

    // *foo* — emphasis node spans the whole construct; the consumed
    // delimiters are covered by no node.
    {
        var result = try oliver.parse(testing.allocator, "*foo*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        const em = p.children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(source.Span{ .start = 0, .end = 5 }, em.span);
        const t = em.children.items[0];
        try testing.expectEqual(document.Tag.text, t.tag);
        try testing.expectEqualStrings("foo", t.data.text);
        try testing.expectEqual(source.Span{ .start = 1, .end = 4 }, t.span);
    }
    // A bare run with no opener is literal text (spec example 357:
    // `*foo bar *` — note the opener is not followed by a space, so the
    // line is not a list item).
    {
        var result = try oliver.parse(testing.allocator, "*foo bar *", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("*foo bar *", p.children.items[0].data.text);
    }
}

test "markdown: intraword asterisks work, underscores do not" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "foo*bar*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("foo", p.children.items[0].data.text);
        try testing.expectEqual(document.Tag.emphasis, p.children.items[1].tag);
    }
    {
        var result = try oliver.parse(testing.allocator, "5*6*78", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqual(document.Tag.emphasis, p.children.items[1].tag);
        try testing.expectEqual(document.Tag.text, p.children.items[2].tag);
        try testing.expectEqualStrings("5", p.children.items[0].data.text);
        try testing.expectEqualStrings("6", p.children.items[1].children.items[0].data.text);
        try testing.expectEqualStrings("78", p.children.items[2].data.text);
    }
    {
        var result = try oliver.parse(testing.allocator, "foo_bar_baz", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("foo_bar_baz", p.children.items[0].data.text);
    }
    {
        var result = try oliver.parse(testing.allocator, "5__6__78", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("5__6__78", p.children.items[0].data.text);
    }
}

test "markdown: strong emphasis and nesting" {
    const oliver = @import("oliver.zig");

    {
        var result = try oliver.parse(testing.allocator, "**foo**", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.strong, p.children.items[0].tag);
        try testing.expectEqualStrings("foo", p.children.items[0].children.items[0].data.text);
    }
    // *foo **bar** baz* nests.
    {
        var result = try oliver.parse(testing.allocator, "*foo **bar** baz*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.emphasis, p.children.items[0].tag);
        const em = p.children.items[0];
        try testing.expectEqual(document.Tag.text, em.children.items[0].tag);
        try testing.expectEqual(document.Tag.strong, em.children.items[1].tag);
        try testing.expectEqual(document.Tag.text, em.children.items[2].tag);
        try testing.expectEqualStrings("foo ", em.children.items[0].data.text);
        try testing.expectEqualStrings("bar", em.children.items[1].children.items[0].data.text);
        try testing.expectEqualStrings(" baz", em.children.items[2].data.text);
    }
}

test "markdown: mod-3 rule (spec examples)" {
    const oliver = @import("oliver.zig");

    // *foo**bar**baz*: the middle ** cannot close against the first *
    // (1+2 = 3), so it opens instead; the second ** closes it as strong.
    {
        var result = try oliver.parse(testing.allocator, "*foo**bar**baz*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(@as(usize, 3), em.children.items.len);
        try testing.expectEqualStrings("foo", em.children.items[0].data.text);
        try testing.expectEqual(document.Tag.strong, em.children.items[1].tag);
        try testing.expectEqualStrings("bar", em.children.items[1].children.items[0].data.text);
        try testing.expectEqualStrings("baz", em.children.items[2].data.text);
    }
    // *foo**bar***: the split closer (`***` closes strong with 2, then the
    // leftover `*` closes the outer emphasis).
    {
        var result = try oliver.parse(testing.allocator, "*foo**bar***", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(@as(usize, 2), em.children.items.len);
        try testing.expectEqual(document.Tag.strong, em.children.items[1].tag);
        try testing.expectEqualStrings("bar", em.children.items[1].children.items[0].data.text);
    }
    // ***foo** bar*: strong consumes ** of the *** opener, the leftover *
    // opens emphasis closed by the final *.
    {
        var result = try oliver.parse(testing.allocator, "***foo** bar*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(document.Tag.strong, em.children.items[0].tag);
        try testing.expectEqualStrings(" bar", em.children.items[1].data.text);
    }
    // **foo*bar*baz** → strong with a literal inner *.
    {
        var result = try oliver.parse(testing.allocator, "**foo*bar*baz**", .markdown, .{});
        defer result.deinit();
        const strong = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.strong, strong.tag);
        try testing.expectEqual(document.Tag.emphasis, strong.children.items[1].tag);
    }
    // **foo*bar** → the trapped * is literal inside strong; the three
    // contiguous text runs merge into one node.
    {
        var result = try oliver.parse(testing.allocator, "**foo*bar**", .markdown, .{});
        defer result.deinit();
        const strong = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.strong, strong.tag);
        try testing.expectEqual(@as(usize, 1), strong.children.items.len);
        try testing.expectEqualStrings("foo*bar", strong.children.items[0].data.text);
        try testing.expectEqual(source.Span{ .start = 2, .end = 9 }, strong.children.items[0].span);
    }
    // The reference behavior for the untested corner case (see matrix).
    {
        var result = try oliver.parse(testing.allocator, "*****Hello*world****", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqual(document.Tag.emphasis, p.children.items[1].tag);
        try testing.expectEqual(document.Tag.text, p.children.items[2].tag);
        try testing.expectEqualStrings("*****Hello", p.children.items[0].data.text);
        try testing.expectEqualStrings("world", p.children.items[1].children.items[0].data.text);
        try testing.expectEqualStrings("***", p.children.items[2].data.text);
    }
}

test "markdown: escaped delimiters are literal, not delimiters" {
    const oliver = @import("oliver.zig");

    // \*foo* — the first * is escaped, so nothing opens; all literal. The
    // escaped * stays its own node (the escape boundary is visible to the
    // renderer's entity decoding), and the trailing literal * merges with
    // "foo".
    {
        var result = try oliver.parse(testing.allocator, "\\*foo*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("*", p.children.items[0].data.text);
        try testing.expectEqualStrings("foo*", p.children.items[1].data.text);
    }
    // \\*emphasis* — the escaped backslash is literal, then real emphasis.
    {
        var result = try oliver.parse(testing.allocator, "\\\\*emphasis*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("\\", p.children.items[0].data.text);
        try testing.expectEqual(document.Tag.emphasis, p.children.items[1].tag);
    }
}

test "markdown: emphasis spans soft and hard breaks" {
    const oliver = @import("oliver.zig");

    {
        var result = try oliver.parse(testing.allocator, "*foo\nbar*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(document.Tag.text, em.children.items[0].tag);
        try testing.expectEqual(document.Tag.soft_break, em.children.items[1].tag);
        try testing.expectEqual(document.Tag.text, em.children.items[2].tag);
    }
    {
        var result = try oliver.parse(testing.allocator, "*foo  \nbar*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.hard_break, em.children.items[1].tag);
    }
}

test "markdown: emphasis in headings" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "# foo *bar* \\*baz\\*", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqualStrings("foo ", h.children.items[0].data.text);
    try testing.expectEqual(document.Tag.emphasis, h.children.items[1].tag);
    try testing.expectEqualStrings("bar", h.children.items[1].children.items[0].data.text);
    // The escaped stars are literal; escape splits never merge the escaped
    // character with the following text (the boundary must stay visible to
    // the renderer's entity decoding), and each escape's backslash leaves a
    // gap, so the model is " ", "*", "baz", "*".
    try testing.expectEqualStrings(" ", h.children.items[2].data.text);
    try testing.expectEqualStrings("*", h.children.items[3].data.text);
    try testing.expectEqualStrings("baz", h.children.items[4].data.text);
    try testing.expectEqualStrings("*", h.children.items[5].data.text);
}

test "markdown: code spans basic structure and content" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "`foo`", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
    try testing.expectEqualStrings("foo", p.children.items[0].data.code_span);
}

test "markdown: code span run-length matching" {
    const oliver = @import("oliver.zig");
    {
        // Open with 2, close with 1: no match; the run of 1 closes a span
        // opened at the first backtick of the pair (spec 335/336 shape).
        var result = try oliver.parse(testing.allocator, "`foo``bar`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo``bar", p.children.items[0].data.code_span);
    }
    {
        // Open with 2, close with 2.
        var result = try oliver.parse(testing.allocator, "``foo``", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo", p.children.items[0].data.code_span);
    }
    {
        // A length-1 run inside a length-2 span is opaque (spec 336).
        var result = try oliver.parse(testing.allocator, "``foo`bar``", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo`bar", p.children.items[0].data.code_span);
    }
    {
        // Content containing a longer run than the delimiters (spec 337).
        var result = try oliver.parse(testing.allocator, "` foo `` bar `", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo `` bar", p.children.items[0].data.code_span);
    }
    {
        // Unmatched opening backticks stay literal (spec 347 shape).
        var result = try oliver.parse(testing.allocator, "`foo", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqualStrings("`foo", p.children.items[0].data.text);
    }
}

test "markdown: code span trim rule uses ASCII spaces only" {
    const oliver = @import("oliver.zig");
    {
        // One space each side is stripped (spec 335).
        var result = try oliver.parse(testing.allocator, "` foo `", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("foo", p.children.items[0].data.code_span);
    }
    {
        // Entirely-space content is kept (spec 339).
        var result = try oliver.parse(testing.allocator, "`  `", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("  ", p.children.items[0].data.code_span);
    }
    {
        // Tabs are not spaces: no trimming (spec 344's note).
        var result = try oliver.parse(testing.allocator, "`\tfoo\t`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("\tfoo\t", p.children.items[0].data.code_span);
    }
    {
        // Only one space is stripped per side.
        var result = try oliver.parse(testing.allocator, "`  foo  `", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings(" foo ", p.children.items[0].data.code_span);
    }
}

test "markdown: code span newlines become spaces and escapes are inert" {
    const oliver = @import("oliver.zig");
    {
        // Line endings inside a code span become spaces.
        var result = try oliver.parse(testing.allocator, "`foo\nbar`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("foo bar", p.children.items[0].data.code_span);
    }
    {
        // Backslash does not escape a backtick; the span closes early
        // (spec 340).
        var result = try oliver.parse(testing.allocator, "`foo\\`bar`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("foo\\", p.children.items[0].data.code_span);
        // The remainder is one contiguous text node: "bar`".
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("bar`", p.children.items[1].data.text);
    }
    {
        // Backslashes inside are kept literally.
        var result = try oliver.parse(testing.allocator, "`a\\b`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("a\\b", p.children.items[0].data.code_span);
    }
}

test "markdown: code span delimits emphasis (opacity precedence)" {
    const oliver = @import("oliver.zig");
    {
        // The star inside the span is not a delimiter (spec 341).
        var result = try oliver.parse(testing.allocator, "*foo`*`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("*foo", p.children.items[0].data.text);
        try testing.expectEqual(document.Tag.code_span, p.children.items[1].tag);
        try testing.expectEqualStrings("*", p.children.items[1].data.code_span);
    }
    {
        // Emphasis wraps a code span (spec 346).
        var result = try oliver.parse(testing.allocator, "*`foo`*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.emphasis, p.children.items[0].tag);
        const em = p.children.items[0];
        try testing.expectEqual(@as(usize, 1), em.children.items.len);
        try testing.expectEqual(document.Tag.code_span, em.children.items[0].tag);
    }
    {
        // A single closing backtick leaves trailing text literal (spec 342).
        var result = try oliver.parse(testing.allocator, "`foo`bar`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqual(document.Tag.code_span, p.children.items[0].tag);
        try testing.expectEqualStrings("bar`", p.children.items[1].data.text);
    }
}

test "markdown: code span node span covers the construct, content excludes backticks" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "a `foo` b", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    const cs = p.children.items[1];
    try testing.expectEqual(document.Tag.code_span, cs.tag);
    // The node span is the whole construct: opening backtick .. closing
    // backtick (2..7). The normalized payload excludes them.
    const s = cs.span;
    try testing.expectEqual(@as(u32, 2), s.start);
    try testing.expectEqual(@as(u32, 7), s.end);
    try testing.expectEqualStrings("foo", cs.data.code_span);
}

// --- inline links (docs/INLINE-PARSING.md §6.6) ---

test "markdown: link structure, spans, and payloads" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo](/uri \"title\")", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const lnk = p.children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    // The node span covers the whole construct: `[` .. `)`.
    try testing.expectEqual(source.Span{ .start = 0, .end = 19 }, lnk.span);
    try testing.expectEqualStrings("/uri", lnk.data.link.href);
    try testing.expectEqualStrings("title", lnk.data.link.title.?);
    // Children are the link text inlines.
    try testing.expectEqual(@as(usize, 1), lnk.children.items.len);
    try testing.expectEqual(document.Tag.text, lnk.children.items[0].tag);
    try testing.expectEqual(source.Span{ .start = 1, .end = 4 }, lnk.children.items[0].span);
    try testing.expectEqualStrings("foo", lnk.children.items[0].data.text);
}

test "markdown: link text holds inlines, not just text" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[a *b* `c`](/u)", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqual(@as(usize, 4), lnk.children.items.len);
    try testing.expectEqual(document.Tag.text, lnk.children.items[0].tag);
    try testing.expectEqual(document.Tag.emphasis, lnk.children.items[1].tag);
    try testing.expectEqual(document.Tag.text, lnk.children.items[2].tag);
    try testing.expectEqual(document.Tag.code_span, lnk.children.items[3].tag);
    try testing.expectEqualStrings("b", lnk.children.items[1].children.items[0].data.text);
}

test "markdown: link destination and title resolve backslash escapes" {
    const oliver = @import("oliver.zig");
    // Markdown source `[x](\(foo\) "ti\*tle")`: escaped parens in the
    // destination, an escaped `*` in the title. The escapes are consumed,
    // so the payloads are arena copies, not source slices (like code_span).
    var result = try oliver.parse(testing.allocator, "[x](\\(foo\\) \"ti\\*tle\")", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqualStrings("(foo)", lnk.data.link.href);
    try testing.expectEqualStrings("ti*tle", lnk.data.link.title.?);
    // A backslash before a non-punctuation character is literal.
    var result2 = try oliver.parse(testing.allocator, "[x](foo\\bar)", .markdown, .{});
    defer result2.deinit();
    const lnk2 = result2.document.root.children.items[0].children.items[0];
    try testing.expectEqualStrings("foo\\bar", lnk2.data.link.href);
}

test "markdown: link brackets bind more tightly than emphasis" {
    const oliver = @import("oliver.zig");
    // `*[foo*](/uri)`: the `*` before `[` cannot open — the link consumes
    // the inner `*` — and the trailing `*` is inside the link text.
    var result = try oliver.parse(testing.allocator, "*[foo*](/uri)", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 2), p.children.items.len);
    try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
    try testing.expectEqualStrings("*", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.link, p.children.items[1].tag);
    try testing.expectEqualStrings("foo*", (try inlineText(&result.document, p.children.items[1])));
}

test "markdown: links cannot contain links, innermost wins" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo [bar](/uri)](/uri)", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // `[foo ` + link + `](/uri)` — the outer brackets stay literal.
    try testing.expectEqual(@as(usize, 3), p.children.items.len);
    try testing.expectEqualStrings("[foo ", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.link, p.children.items[1].tag);
    try testing.expectEqualStrings("bar", (try inlineText(&result.document, p.children.items[1])));
    try testing.expectEqualStrings("](/uri)", p.children.items[2].data.text);
}

test "markdown: code spans bind more tightly than link brackets" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo`](/uri)`", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // The code span runs from the first backtick to the last one, so the
    // `]` never closes the `[` — the whole thing is text + one code span.
    try testing.expectEqual(@as(usize, 2), p.children.items.len);
    try testing.expectEqualStrings("[foo", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.code_span, p.children.items[1].tag);
    try testing.expectEqualStrings("](/uri)", p.children.items[1].data.code_span);
}

test "markdown: emphasis can wrap a link" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "*[foo](/uri)*", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const em = p.children.items[0];
    try testing.expectEqual(document.Tag.emphasis, em.tag);
    try testing.expectEqual(@as(usize, 1), em.children.items.len);
    try testing.expectEqual(document.Tag.link, em.children.items[0].tag);
}

test "markdown: link failures stay literal" {
    const oliver = @import("oliver.zig");
    // Space before `(`: not a link.
    {
        var result = try oliver.parse(testing.allocator, "[foo] (url)", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("[foo] (url)", p.children.items[0].data.text);
    }
    // Unbalanced destination parens: not a link.
    {
        var result = try oliver.parse(testing.allocator, "[foo](bar(baz)", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("[foo](bar(baz)", p.children.items[0].data.text);
    }
    // Unclosed title: not a link.
    {
        var result = try oliver.parse(testing.allocator, "[foo](/url \"x", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("[foo](/url \"x", p.children.items[0].data.text);
    }
    // Balanced brackets inside link text are fine.
    {
        var result = try oliver.parse(testing.allocator, "[a [b] c](/u)", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
        try testing.expectEqualStrings("a [b] c", (try inlineText(&result.document, p.children.items[0])));
    }
}

test "markdown: link text can span lines with a soft break inside" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[a\nb](/u)", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const lnk = p.children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    // Children: `a`, soft break, `b`.
    try testing.expectEqual(@as(usize, 3), lnk.children.items.len);
    try testing.expectEqual(document.Tag.soft_break, lnk.children.items[1].tag);
    // The link consumes the `(/u)` bytes; nothing literal leaks after it.
    try testing.expectEqual(source.Span{ .start = 0, .end = 9 }, lnk.span);
}

test "markdown: link title spans lines, destination does not" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[x](/u 't\na')", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const lnk = p.children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("t\na", lnk.data.link.title.?);

    // A destination cannot contain a line ending (unlike a separator:
    // `[x](/u\n'a')` above is a valid link with a one-line-ending
    // separator). Here the line ending is inside the would-be destination,
    // so no link forms and the two lines stay a paragraph with a soft
    // break — rendering `[x](/u\nv)`, the spec's shape.
    var result2 = try oliver.parse(testing.allocator, "[x](/u\nv)", .markdown, .{});
    defer result2.deinit();
    const p2 = result2.document.root.children.items[0];
    // text `[x](/u`, soft break, text `v)` — renders `[x](/u\nv)`.
    try testing.expectEqual(@as(usize, 3), p2.children.items.len);
    try testing.expectEqualStrings("[x](/u", p2.children.items[0].data.text);
    try testing.expectEqual(document.Tag.soft_break, p2.children.items[1].tag);
    try testing.expectEqualStrings("v)", p2.children.items[2].data.text);
}

test "markdown: link in heading, empty href, quote destination" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "# [foo](/uri)", .markdown, .{});
        defer result.deinit();
        const h = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.heading, h.tag);
        try testing.expectEqual(document.Tag.link, h.children.items[0].tag);
    }
    {
        var result = try oliver.parse(testing.allocator, "[x]()", .markdown, .{});
        defer result.deinit();
        const lnk = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.link, lnk.tag);
        try testing.expectEqualStrings("", lnk.data.link.href);
        try testing.expectEqual(@as(?[]const u8, null), lnk.data.link.title);
    }
    // `[link]("title")`: the quoted string parses as a destination.
    {
        var result = try oliver.parse(testing.allocator, "[link](\"title\")", .markdown, .{});
        defer result.deinit();
        const lnk = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.link, lnk.tag);
        try testing.expectEqualStrings("\"title\"", lnk.data.link.href);
        try testing.expectEqual(@as(?[]const u8, null), lnk.data.link.title);
    }
}

// --- inline images (docs/IMAGES-PARSING.md) ---

test "markdown: image structure, spans, and payloads" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "![foo](/uri \"title\")", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const img = p.children.items[0];
    try testing.expectEqual(document.Tag.image, img.tag);
    // The node span covers the whole construct: `![` .. `)`.
    try testing.expectEqual(source.Span{ .start = 0, .end = 20 }, img.span);
    try testing.expectEqualStrings("/uri", img.data.image.src);
    try testing.expectEqualStrings("foo", img.data.image.alt);
    try testing.expectEqualStrings("title", img.data.image.title.?);
    // Leaf inline: no children (the description lives in the alt string).
    try testing.expectEqual(@as(usize, 0), img.children.items.len);
}

test "markdown: image alt flattens description inlines" {
    const oliver = @import("oliver.zig");
    // Emphasis, strong, and code spans all flatten to plain string content
    // (docs/IMAGES-PARSING.md §3: "only the plain string content ...").
    {
        var result = try oliver.parse(testing.allocator, "![foo *bar*](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo bar", img.data.image.alt);
    }
    {
        var result = try oliver.parse(testing.allocator, "![*a* **b** `c`](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("a b c", img.data.image.alt);
    }
    // Escapes resolve in the description.
    {
        var result = try oliver.parse(testing.allocator, "![foo \\*bar\\*](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo *bar*", img.data.image.alt);
    }
    // Escaped and unmatched brackets are literal content.
    {
        var result = try oliver.parse(testing.allocator, "![foo\\]bar](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo]bar", img.data.image.alt);
    }
    {
        var result = try oliver.parse(testing.allocator, "![foo [bar] baz](/u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo [bar] baz", img.data.image.alt);
    }
    // Empty description → empty alt (spec example 581).
    {
        var result = try oliver.parse(testing.allocator, "![](/url)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("", img.data.image.alt);
    }
}

test "markdown: images may contain links and images, links may contain images" {
    const oliver = @import("oliver.zig");
    // Image description contains a link (spec example 575).
    {
        var result = try oliver.parse(testing.allocator, "![foo [bar](/url)](/url2)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url2", img.data.image.src);
        try testing.expectEqualStrings("foo bar", img.data.image.alt);
    }
    // Image description contains an image (spec example 574).
    {
        var result = try oliver.parse(testing.allocator, "![foo ![bar](/url)](/url2)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("foo bar", img.data.image.alt);
    }
    // Links may contain images (spec example 540): the image is a child
    // node of the link.
    {
        var result = try oliver.parse(testing.allocator, "[![moon](moon.jpg)](/uri)", .markdown, .{});
        defer result.deinit();
        const lnk = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.link, lnk.tag);
        try testing.expectEqual(@as(usize, 1), lnk.children.items.len);
        try testing.expectEqual(document.Tag.image, lnk.children.items[0].tag);
        try testing.expectEqualStrings("moon", lnk.children.items[0].data.image.alt);
    }
    // A link inside the description does not kill the image opener, and a
    // dead `[` above a live `![` intercepts a `]` (the appendix's
    // inactive-bracket semantics; docs/IMAGES-PARSING.md §2).
    {
        var result = try oliver.parse(testing.allocator, "![foo [bar [baz](/u)](/u2)](/u3)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("foo [bar baz](/u2)", img.data.image.alt);
    }
}

test "markdown: image openers require an unescaped bang and bracket" {
    const oliver = @import("oliver.zig");
    // Escaped `[`: literal `![foo]` (spec example 592 shape).
    {
        var result = try oliver.parse(testing.allocator, "!\\[foo]", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("![foo]", try inlineText(&result.document, p));
        try testing.expectEqual(@as(usize, 0), countImages(&result.document));
    }
    // Escaped `!`: literal `!` then `[foo]` (spec example 593 shape;
    // reference links are deferred, so the brackets stay literal).
    {
        var result = try oliver.parse(testing.allocator, "\\![foo]", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqualStrings("![foo]", try inlineText(&result.document, p));
        try testing.expectEqual(@as(usize, 0), countImages(&result.document));
    }
    // A plain `!` not followed by `[` is just text.
    {
        var result = try oliver.parse(testing.allocator, "hello! world", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 1), p.children.items.len);
        try testing.expectEqualStrings("hello! world", p.children.items[0].data.text);
    }
}

test "markdown: image in heading and emphasis; code spans keep it from closing" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "# ![foo](/url)", .markdown, .{});
        defer result.deinit();
        const h = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.heading, h.tag);
        try testing.expectEqual(document.Tag.image, h.children.items[0].tag);
    }
    {
        var result = try oliver.parse(testing.allocator, "*![foo](/url)*", .markdown, .{});
        defer result.deinit();
        const em = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(document.Tag.image, em.children.items[0].tag);
    }
    // Code spans bind more tightly than brackets: the `]` inside the span
    // never closes the image, so it stays literal (`` ![foo`](/uri)` ``).
    {
        var result = try oliver.parse(testing.allocator, "![foo`](/uri)`", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 2), p.children.items.len);
        try testing.expectEqualStrings("![foo", p.children.items[0].data.text);
        try testing.expectEqual(document.Tag.code_span, p.children.items[1].tag);
        try testing.expectEqualStrings("](/uri)", p.children.items[1].data.code_span);
    }
}

test "markdown: image destination and title resolve backslash escapes" {
    const oliver = @import("oliver.zig");
    // `![x](\(foo\) \"ti\\*tle\")`: escaped parens in the destination
    // and an escaped `*` in the title, resolved into arena-owned payloads
    // exactly like a link's.
    var result = try oliver.parse(testing.allocator, "![x](\\(foo\\) \"ti\\*tle\")", .markdown, .{});
    defer result.deinit();
    const img = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.image, img.tag);
    try testing.expectEqualStrings("(foo)", img.data.image.src);
    try testing.expectEqualStrings("ti*tle", img.data.image.title.?);
    try testing.expectEqual(@as(usize, 0), img.children.items.len);
}

test "markdown: reference-style images resolve from definitions (full, collapsed, shortcut)" {
    const oliver = @import("oliver.zig");

    // Full: ![foo][bar] resolves through the definition table.
    {
        var result = try oliver.parse(testing.allocator, "![foo][bar]\n\n[bar]: /url\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
        try testing.expectEqualStrings("foo", img.data.image.alt);
        try testing.expectEqual(@as(?[]const u8, null), img.data.image.title);
        try testing.expectEqual(@as(usize, 1), countImages(&result.document));
    }

    // Collapsed: ![foo][] uses the opener's own text as the label.
    {
        var result = try oliver.parse(testing.allocator, "![foo][]\n\n[foo]: /url \"title\"\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
        try testing.expectEqualStrings("foo", img.data.image.alt);
        try testing.expectEqualStrings("title", img.data.image.title.?);
    }

    // Shortcut: ![foo] with no trailing label.
    {
        var result = try oliver.parse(testing.allocator, "![foo]\n\n[foo]: /url\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
        try testing.expectEqualStrings("foo", img.data.image.alt);
    }
}

test "markdown: reference-style image descriptions flatten to alt" {
    const oliver = @import("oliver.zig");

    // Emphasis drops its markers; the label matches the *raw* bracket
    // text (matching is on normalized strings, not parsed content).
    {
        var result = try oliver.parse(testing.allocator, "![*foo* bar][]\n\n[*foo* bar]: /url\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
        try testing.expectEqualStrings("foo bar", img.data.image.alt);
    }

    // Case-insensitive labels: ![Foo][] matches [foo]:
    {
        var result = try oliver.parse(testing.allocator, "![Foo][]\n\n[foo]: /url \"title\"\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("Foo", img.data.image.alt); // alt keeps the source text
    }
}

test "markdown: reference precedence and image inline beats reference" {
    const oliver = @import("oliver.zig");

    // Inline destination wins over the reference form (appendix order).
    {
        var result = try oliver.parse(testing.allocator, "![foo](inline \"t\")\n\n[foo]: /url\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("inline", img.data.image.src);
        try testing.expectEqualStrings("t", img.data.image.title.?);
    }

    // A failed full reference is not retried as a shortcut: with both
    // [bar] and [foo] defined, ![foo][bar] is the full reference to /url;
    // the opener's own text ([foo]) is never tried.
    {
        var result = try oliver.parse(testing.allocator, "![foo][bar]\n\n[bar]: /url\n[foo]: /url2\n", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("/url", img.data.image.src);
    }
}

test "markdown: reference-style image inside reference-link text" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[![foo][bar]][baz]\n\n[bar]: /img\n[baz]: /page\n", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("/page", lnk.data.link.href);
    const img = lnk.children.items[0];
    try testing.expectEqual(document.Tag.image, img.tag);
    try testing.expectEqualStrings("/img", img.data.image.src);
    try testing.expectEqualStrings("foo", img.data.image.alt);
}

test "markdown: unmatched reference image stays literal and shares the inactive-bracket rule" {
    const oliver = @import("oliver.zig");

    // No definition: ![foo][bar] stays literal text.
    {
        var result = try oliver.parse(testing.allocator, "![foo][bar]\n", .markdown, .{});
        defer result.deinit();
        try testing.expectEqual(@as(usize, 0), countImages(&result.document));
        const para = result.document.root.children.items[0];
        try testing.expectEqualStrings("![foo][bar]", try inlineText(&result.document, para));
    }

    // A formed reference *link* inactivates earlier `[` openers, never a
    // `![`; a dead `[` still intercepts a later `]` (appendix rule).
    // `![a [b][c]]` — the inner [b][c] is a reference link, so `![a <link>`;
    // the image opener below the dead `[` cannot use that `]`.
    {
        var result = try oliver.parse(testing.allocator, "![a [b][c]]\n\n[c]: /url\n", .markdown, .{});
        defer result.deinit();
        // The image does not form: the inner link consumed the bracket.
        try testing.expectEqual(@as(usize, 0), countImages(&result.document));
    }
}

// --- autolinks (docs/AUTOLINKS.md §6.8) ---

test "markdown: URI autolink structure, spans, and payloads" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "<http://foo.bar.baz>", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    const a = p.children.items[0];
    try testing.expectEqual(document.Tag.autolink, a.tag);
    // The node span covers the whole `<...>` construct (20 bytes).
    try testing.expectEqual(source.Span{ .start = 0, .end = 20 }, a.span);
    // URI autolinks: href == label == the raw content, verbatim.
    try testing.expectEqualStrings("http://foo.bar.baz", a.data.autolink.href);
    try testing.expectEqualStrings("http://foo.bar.baz", a.data.autolink.label);
    // Leaf inline: no children.
    try testing.expectEqual(@as(usize, 0), a.children.items.len);
}

test "markdown: email autolinks get mailto: href" {
    const oliver = @import("oliver.zig");
    {
        var result = try oliver.parse(testing.allocator, "<foo@bar.example.com>", .markdown, .{});
        defer result.deinit();
        const a = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.autolink, a.tag);
        try testing.expectEqualStrings("mailto:foo@bar.example.com", a.data.autolink.href);
        try testing.expectEqualStrings("foo@bar.example.com", a.data.autolink.label);
    }
    // Case is preserved in both href and label (§6.8: "case-insensitive").
    {
        var result = try oliver.parse(testing.allocator, "<FOO@BAR.COM>", .markdown, .{});
        defer result.deinit();
        const a = result.document.root.children.items[0].children.items[0];
        try testing.expectEqualStrings("mailto:FOO@BAR.COM", a.data.autolink.href);
        try testing.expectEqualStrings("FOO@BAR.COM", a.data.autolink.label);
    }
}

test "markdown: backslash escapes are inert inside autolinks" {
    const oliver = @import("oliver.zig");
    // §6.8: neither the URI nor the email may contain spaces, and
    // backslash escapes do not work inside autolinks — the content is
    // copied verbatim (unlike links, whose destination is escape-resolved).
    var result = try oliver.parse(testing.allocator, "<https://example.com/\\[\\>", .markdown, .{});
    defer result.deinit();
    const a = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.autolink, a.tag);
    try testing.expectEqualStrings("https://example.com/\\[\\", a.data.autolink.href);
    try testing.expectEqualStrings("https://example.com/\\[\\", a.data.autolink.label);
}

test "markdown: non-autolinks stay literal" {
    const oliver = @import("oliver.zig");
    // §6.8 negatives: empty, spaces, 1-char scheme, bare domain. The
    // `\\+` case stays literal text but the escape *does* resolve outside
    // autolinks (escapes only fail to work *inside* `<...>`), so its text
    // is `<foo+@bar.example.com>`.
    const inputs = [_][2][]const u8{
        .{ "<>", "<>" },
        .{ "< https://foo.bar >", "< https://foo.bar >" },
        .{ "<m:abc>", "<m:abc>" },
        .{ "<foo.bar.baz>", "<foo.bar.baz>" },
        .{ "<foo\\+@bar.example.com>", "<foo+@bar.example.com>" },
        .{ "<https://foo.bar/baz bim>", "<https://foo.bar/baz bim>" },
    };
    for (inputs) |input| {
        var result = try oliver.parse(testing.allocator, input[0], .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 0), countAutolinks(&result.document));
        // And no accidental link/image either: it stays plain text.
        try testing.expectEqualStrings(input[1], try inlineText(&result.document, p));
    }
}

test "markdown: autolinks nest inside emphasis and link text" {
    const oliver = @import("oliver.zig");
    // Emphasis around an autolink: *<http://foo.bar>*
    {
        var result = try oliver.parse(testing.allocator, "*<http://foo.bar>*", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        const em = p.children.items[0];
        try testing.expectEqual(document.Tag.emphasis, em.tag);
        try testing.expectEqual(document.Tag.autolink, em.children.items[0].tag);
    }
    // §6.8 precedence: the autolink swallows what looks like link syntax
    // (spec example 526) — `](uri)` is inside the autolink content. The
    // `[` before it stays literal text (no link forms), so the paragraph
    // children are [text "[", autolink].
    {
        var result = try oliver.parse(testing.allocator, "[<https://example.com/?search=](uri)>", .markdown, .{});
        defer result.deinit();
        const kids = result.document.root.children.items[0].children.items;
        try testing.expectEqual(@as(usize, 2), kids.len);
        try testing.expectEqual(document.Tag.text, kids[0].tag);
        try testing.expectEqualStrings("[", kids[0].data.text);
        const a = kids[1];
        try testing.expectEqual(document.Tag.autolink, a.tag);
        try testing.expectEqualStrings("https://example.com/?search=](uri)", a.data.autolink.href);
        try testing.expectEqual(@as(usize, 0), countLinks(&result.document));
    }
}

test "markdown: autolink in an image description flattens into alt" {
    const oliver = @import("oliver.zig");
    // The alt string is the description rendered as plain text, so the
    // autolink contributes its label (`http://x`, no `<...>`).
    var result = try oliver.parse(testing.allocator, "![<http://x>](img)", .markdown, .{});
    defer result.deinit();
    const img = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.image, img.tag);
    try testing.expectEqualStrings("http://x", img.data.image.alt);
}

test "markdown: raw HTML leaves preserve spans and first-come opacity" {
    const oliver = @import("oliver.zig");

    // A tag is opaque to brackets and emphasis, but its source bytes remain
    // available through the leaf span. The backtick pair inside the quoted
    // attribute must not become a code span because the tag starts first.
    const input = "*<b data=\"`x`\">[x]</b>*";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();
    const em = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.emphasis, em.tag);
    try testing.expectEqual(@as(usize, 3), em.children.items.len);
    try testing.expectEqual(document.Tag.raw_html, em.children.items[0].tag);
    try testing.expectEqual(source.Span{ .start = 1, .end = 15 }, em.children.items[0].span);
    try testing.expectEqualStrings("<b data=\"`x`\">", input[1..15]);
    try testing.expectEqual(document.Tag.text, em.children.items[1].tag);
    try testing.expectEqual(document.Tag.raw_html, em.children.items[2].tag);
    try testing.expectEqual(source.Span{ .start = 18, .end = 22 }, em.children.items[2].span);

    // Conversely, a code span that starts first keeps a tag-looking string
    // opaque and emits one code_span leaf.
    var code_result = try oliver.parse(testing.allocator, "`<b>`", .markdown, .{});
    defer code_result.deinit();
    const code_p = code_result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), code_p.children.items.len);
    try testing.expectEqual(document.Tag.code_span, code_p.children.items[0].tag);

    // A tag that starts first also wins when its attribute contains a
    // complete backtick pair. (A bare tag alone on a line is a type-7 HTML
    // block, §4.6, so the inline-tag precedence is exercised in paragraph
    // context.)
    var tag_result = try oliver.parse(testing.allocator, "x <b title=\"`x`\">", .markdown, .{});
    defer tag_result.deinit();
    const tag_p = tag_result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 2), tag_p.children.items.len);
    try testing.expectEqual(document.Tag.text, tag_p.children.items[0].tag);
    try testing.expectEqual(document.Tag.raw_html, tag_p.children.items[1].tag);
}

test "markdown: raw HTML preserves multiline bytes and flattens image alt" {
    const oliver = @import("oliver.zig");

    // The two spaces before the newline are inside the quoted attribute, so
    // this line ending is raw HTML content, not a hard break.
    {
        const input = "before <a href=\"foo  \nbar\"> after";
        var result = try oliver.parse(testing.allocator, input, .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(@as(usize, 3), p.children.items.len);
        try testing.expectEqual(document.Tag.raw_html, p.children.items[1].tag);
        const raw = p.children.items[1];
        try testing.expectEqualStrings("<a href=\"foo  \nbar\">", input[raw.span.start..raw.span.end]);

        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
        var out = aw.toArrayList();
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>before <a href=\"foo  \nbar\"> after</p>\n", out.items);
    }

    // Raw HTML contributes its source bytes to the deliberately chosen
    // image-alt flattening policy; the image renderer then escapes them.
    {
        var result = try oliver.parse(testing.allocator, "![<b>x</b>](u)", .markdown, .{});
        defer result.deinit();
        const img = result.document.root.children.items[0].children.items[0];
        try testing.expectEqual(document.Tag.image, img.tag);
        try testing.expectEqualStrings("<b>x</b>", img.data.image.alt);
    }
}

test "markdown: entity references decode in text but not code or raw HTML" {
    const oliver = @import("oliver.zig");

    // Named and numeric references decode in text (§2.5); `&amp;` decodes
    // to `&` and re-escapes, and an entity-produced `*` is not a delimiter.
    {
        var result = try oliver.parse(testing.allocator, "&nbsp; &amp; &#35; &#X22; &#42;foo&#42;", .markdown, .{});
        defer result.deinit();
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
        var out = aw.toArrayList();
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>\u{a0} &amp; # &quot; *foo*</p>\n", out.items);
    }

    // Nonentities and backslash-escaped ampersands stay literal: the
    // escaped `&` must not be decoded as part of a reference.
    {
        var result = try oliver.parse(testing.allocator, "&copy &MadeUpEntity; \\&ouml;", .markdown, .{});
        defer result.deinit();
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
        var out = aw.toArrayList();
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>&amp;copy &amp;MadeUpEntity; &amp;ouml;</p>\n", out.items);
    }

    // References are literal inside code spans and code blocks.
    {
        var result = try oliver.parse(testing.allocator, "`&amp;`\n\n    &amp;\n", .markdown, .{});
        defer result.deinit();
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
        var out = aw.toArrayList();
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><code>&amp;amp;</code></p>\n<pre><code>&amp;amp;\n</code></pre>\n", out.items);
    }

    // A decoded tab and newline are text bytes, not breaks or indentation.
    {
        var result = try oliver.parse(testing.allocator, "&#9;foo\n\nfoo&#10;&#10;bar", .markdown, .{});
        defer result.deinit();
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
        var out = aw.toArrayList();
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>\tfoo</p>\n<p>foo\n\nbar</p>\n", out.items);
    }
}

test "markdown: HTML block types 6 and 7" {
    const oliver = @import("oliver.zig");

    // Type 6: a block tag on its own line; content is verbatim and ends at
    // a blank line. The `<table>` line is a complete type-6 start even with
    // attributes.
    {
        var result = try oliver.parse(testing.allocator, "<div id=\"foo\">\n  *hello*\n\nokay.", .markdown, .{});
        defer result.deinit();
        const root = result.document.root;
        try testing.expectEqual(document.Tag.html_block, root.children.items[0].tag);
        try testing.expectEqualStrings("<div id=\"foo\">\n  *hello*\n", root.children.items[0].data.html_block);
        try testing.expectEqual(document.Tag.paragraph, root.children.items[1].tag);
    }

    // Type 7: a complete open tag with a non-block name; cannot interrupt a
    // paragraph, so it is only a block at a fresh start.
    {
        var result = try oliver.parse(testing.allocator, "<a href=\"bar\">\n*foo*\n</a>", .markdown, .{});
        defer result.deinit();
        const root = result.document.root;
        try testing.expectEqual(@as(usize, 1), root.children.items.len);
        try testing.expectEqual(document.Tag.html_block, root.children.items[0].tag);
        try testing.expectEqualStrings("<a href=\"bar\">\n*foo*\n</a>", root.children.items[0].data.html_block);
    }
    {
        var result = try oliver.parse(testing.allocator, "Foo\n<a href=\"bar\">\nbaz", .markdown, .{});
        defer result.deinit();
        const p = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.paragraph, p.tag);
        try testing.expectEqual(document.Tag.text, p.children.items[0].tag);
        try testing.expectEqual(document.Tag.soft_break, p.children.items[1].tag);
        try testing.expectEqual(document.Tag.raw_html, p.children.items[2].tag);
    }

    // Type 6 can interrupt a paragraph; type 7 cannot.
    {
        var result = try oliver.parse(testing.allocator, "Foo\n<div>\nbar", .markdown, .{});
        defer result.deinit();
        const root = result.document.root;
        try testing.expectEqual(document.Tag.paragraph, root.children.items[0].tag);
        try testing.expectEqual(document.Tag.html_block, root.children.items[1].tag);
    }

    // `pre`/`script`/`style`/`textarea` belong to type 1: an open tag on its
    // own line is an HTML block (ending at its matching closing tag), not a
    // type-7 block (which excludes those names).
    {
        var result = try oliver.parse(testing.allocator, "<pre>\nfoo\n</pre>", .markdown, .{});
        defer result.deinit();
        const root = result.document.root;
        try testing.expectEqual(@as(usize, 1), root.children.items.len);
        try testing.expectEqual(document.Tag.html_block, root.children.items[0].tag);
        try testing.expectEqualStrings("<pre>\nfoo\n</pre>", root.children.items[0].data.html_block);
    }

    // Container prefixes are stripped; content is verbatim otherwise.
    {
        var result = try oliver.parse(testing.allocator, "> <div>\n> foo\n\nbar", .markdown, .{});
        defer result.deinit();
        const quote = result.document.root.children.items[0];
        try testing.expectEqual(document.Tag.block_quote, quote.tag);
        try testing.expectEqual(document.Tag.html_block, quote.children.items[0].tag);
        try testing.expectEqualStrings("<div>\nfoo\n", quote.children.items[0].data.html_block);
    }
}

/// Counts `.autolink` nodes in a document (structural assertions).
fn countAutolinks(doc: *document.Document) usize {
    var it = document.Document.Iterator.init(doc.allocator(), doc.root) catch return 0;
    defer it.deinit();
    var n: usize = 0;
    while (it.next() catch null) |node| {
        if (node.tag == .autolink) n += 1;
    }
    return n;
}

/// Counts `.link` nodes in a document (structural assertions).
fn countLinks(doc: *document.Document) usize {
    var it = document.Document.Iterator.init(doc.allocator(), doc.root) catch return 0;
    defer it.deinit();
    var n: usize = 0;
    while (it.next() catch null) |node| {
        if (node.tag == .link) n += 1;
    }
    return n;
}

/// Counts `.image` nodes in a document (structural assertions).
fn countImages(doc: *document.Document) usize {
    var it = document.Document.Iterator.init(doc.allocator(), doc.root) catch return 0;
    defer it.deinit();
    var n: usize = 0;
    while (it.next() catch null) |node| {
        if (node.tag == .image) n += 1;
    }
    return n;
}

/// Concatenates a node's inline text payloads (escapes split text into
/// adjacent nodes, so structural tests join them).
fn inlineText(doc: *document.Document, node: *document.Node) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(doc.allocator());
    for (node.children.items) |child| {
        try buf.appendSlice(doc.allocator(), child.data.text);
    }
    return buf.toOwnedSlice(doc.allocator());
}

test "markdown: full reference link with title" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo][bar]\n\n[bar]: /url \"title\"\n", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("/url", lnk.data.link.href);
    try testing.expectEqualStrings("title", lnk.data.link.title.?);
}

test "markdown: collapsed reference link" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo][]\n\n[foo]: /url\n", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("/url", lnk.data.link.href);
}

test "markdown: reference precedence over shortcut" {
    const oliver = @import("oliver.zig");
    // Both foo and bar defined: [foo][bar] is a full reference to bar.
    var result = try oliver.parse(testing.allocator, "[foo][bar]\n\n[foo]: /url1\n[bar]: /url2\n", .markdown, .{});
    defer result.deinit();
    const lnk = result.document.root.children.items[0].children.items[0];
    try testing.expectEqual(document.Tag.link, lnk.tag);
    try testing.expectEqualStrings("/url2", lnk.data.link.href);
}

test "markdown: failed inline falls through to shortcut" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo](not a link)\n\n[foo]: /url1\n", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // link foo + literal text `(not a link)`.
    try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
    try testing.expectEqualStrings("foo", p.children.items[0].children.items[0].data.text);
    try testing.expectEqualStrings("(not a link)", p.children.items[1].data.text);
}

test "markdown: label normalization matches across whitespace and case" {
    const oliver = @import("oliver.zig");
    // The spec's own examples: Unicode case fold (ẞ matches SS), and
    // internal whitespace collapse ([Foo\n  bar] matches [Foo bar]).
    var r1 = try oliver.parse(testing.allocator, "[ẞ]\n\n[SS]: /url\n", .markdown, .{});
    defer r1.deinit();
    try testing.expectEqual(document.Tag.link, r1.document.root.children.items[0].children.items[0].tag);

    var r2 = try oliver.parse(testing.allocator, "[Foo\n  bar]: /url\n\n[Baz][Foo bar]\n", .markdown, .{});
    defer r2.deinit();
    try testing.expectEqual(document.Tag.link, r2.document.root.children.items[0].children.items[0].tag);
}

test "markdown: no link when label undefined; brackets stay literal" {
    const oliver = @import("oliver.zig");
    // Shortcut with no definition, and full reference with no definition
    // for the label but one for the text (so `[foo]` is not a shortcut
    // either, being followed by a link label).
    var result = try oliver.parse(testing.allocator, "[foo][bar][baz]\n\n[baz]: /url1\n[foo]: /url2\n", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    // `[foo]` literal, then a link for `[bar][baz]`.
    try testing.expectEqualStrings("[foo]", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.link, p.children.items[1].tag);
    try testing.expectEqualStrings("bar", p.children.items[1].children.items[0].data.text);
}

test "markdown: angle destination directly followed by a title is not a definition (§4.7 example 201)" {
    const oliver = @import("oliver.zig");
    // `[foo]: <bar>(baz)` — the `(baz)` title follows the angle
    // destination with no separating whitespace, so the line is ordinary
    // text and `[foo]` is a literal shortcut that resolves nothing.
    const input = "[foo]: <bar>(baz)\n\n[foo]\n";
    var result = try oliver.parse(testing.allocator, input, .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    const p1 = root.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p1.tag);
    // Text before the tag, the raw inline HTML, then the text after it.
    try testing.expectEqual(@as(usize, 3), p1.children.items.len);
    try testing.expectEqual(document.Tag.text, p1.children.items[0].tag);
    try testing.expectEqualStrings("[foo]: ", p1.children.items[0].data.text);
    try testing.expectEqual(document.Tag.raw_html, p1.children.items[1].tag);
    const raw = p1.children.items[1];
    try testing.expectEqualStrings("<bar>", input[raw.span.start..raw.span.end]);
    try testing.expectEqual(document.Tag.text, p1.children.items[2].tag);
    try testing.expectEqualStrings("(baz)", p1.children.items[2].data.text);
    // Not a definition, so `[foo]` resolves nothing and stays literal text.
    const p2 = root.children.items[1];
    try testing.expectEqual(document.Tag.paragraph, p2.tag);
    try testing.expectEqual(document.Tag.text, p2.children.items[0].tag);
    try testing.expectEqualStrings("[foo]", p2.children.items[0].data.text);
}

test "markdown: definition-only paragraph produces no block" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo]: /url\n\nbar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expectEqualStrings("bar", root.children.items[0].children.items[0].data.text);
}

test "markdown: shortcut reference resolves (definition after use)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "[foo]\n\n[foo]: /url\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    const p = root.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
    try testing.expectEqualStrings("/url", p.children.items[0].data.link.href);
}

test "markdown: basic block quote contains its blocks, markers stripped" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> foo\n> bar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    const bq = root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    // The quote span covers the stripped content: 2 (the marker) .. end
    // of the last line's content (byte 11 = after `> bar`).
    try testing.expectEqual(@as(u32, 2), bq.span.start);
    try testing.expectEqual(@as(u32, 11), bq.span.end);
    try testing.expectEqual(@as(usize, 1), bq.children.items.len);
    const p = bq.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    // One paragraph with a soft break; the marker bytes are not in spans.
    try testing.expectEqual(@as(u32, 2), p.span.start);
    try testing.expectEqual(@as(u32, 11), p.span.end);
    try testing.expectEqual(@as(usize, 3), p.children.items.len);
    try testing.expectEqualStrings("foo", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.soft_break, p.children.items[1].tag);
    try testing.expectEqualStrings("bar", p.children.items[2].data.text);
}

test "markdown: nested block quotes" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> > foo\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    const outer = root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, outer.tag);
    const inner = outer.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, inner.tag);
    const p = inner.children.items[0];
    try testing.expectEqualStrings("foo", p.children.items[0].data.text);
    try testing.expectEqual(@as(u32, 4), p.span.start); // "> > " = 4 bytes
}

test "markdown: lazy continuation keeps the quote; markers stay open" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> foo\nbar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    const bq = root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    const p = bq.children.items[0];
    try testing.expectEqualStrings("foo", p.children.items[0].data.text);
    // The lazy line's span starts at column 0 (no marker to strip).
    try testing.expectEqualStrings("bar", p.children.items[2].data.text);
    try testing.expectEqual(@as(u32, 6), p.children.items[2].span.start);
    // The quote span extends to cover the lazy line (byte 9 = after `bar`).
    try testing.expectEqual(@as(u32, 9), bq.span.end);
}

test "markdown: block quote interrupts a paragraph" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "foo\n> bar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, root.children.items[0].tag);
    try testing.expectEqual(document.Tag.block_quote, root.children.items[1].tag);
    const p = root.children.items[1].children.items[0];
    try testing.expectEqualStrings("bar", p.children.items[0].data.text);
}

test "markdown: blank line separates block quotes; marker blank keeps one" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> foo\n\n> bar\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 2), root.children.items.len);
    try testing.expectEqual(document.Tag.block_quote, root.children.items[0].tag);
    try testing.expectEqual(document.Tag.block_quote, root.children.items[1].tag);

    var result2 = try oliver.parse(testing.allocator, "> foo\n>\n> bar\n", .markdown, .{});
    defer result2.deinit();
    const root2 = result2.document.root;
    try testing.expectEqual(@as(usize, 1), root2.children.items.len);
    try testing.expectEqual(@as(usize, 2), root2.children.items[0].children.items.len);
}

test "markdown: empty block quote and marker-only lines" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, ">\n>  \n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expectEqual(document.Tag.block_quote, root.children.items[0].tag);
    try testing.expectEqual(@as(usize, 0), root.children.items[0].children.items.len);
}

test "markdown: definitions inside a block quote register document-wide" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "> [foo]: /url\n> [foo]\n", .markdown, .{});
    defer result.deinit();
    const root = result.document.root;
    // The definition paragraph vanishes; the quote contains only the use.
    const bq = root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    try testing.expectEqual(@as(usize, 1), bq.children.items.len);
    const p = bq.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqual(document.Tag.link, p.children.items[0].tag);
    try testing.expectEqualStrings("/url", p.children.items[0].data.link.href);
}

test "markdown: lists merge by bullet or ordered delimiter" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "- one\n- two\n+ three\n10) ten\n20) twenty\n",
        .markdown,
        .{},
    );
    defer result.deinit();

    const root = result.document.root;
    try testing.expectEqual(@as(usize, 3), root.children.items.len);

    const dash = root.children.items[0];
    try testing.expectEqual(document.Tag.list, dash.tag);
    try testing.expectEqual(document.ListKind.bullet, dash.data.list.kind);
    try testing.expectEqual(@as(u8, '-'), dash.data.list.bullet);
    try testing.expectEqual(@as(usize, 2), dash.children.items.len);

    const plus = root.children.items[1];
    try testing.expectEqual(document.Tag.list, plus.tag);
    try testing.expectEqual(document.ListKind.bullet, plus.data.list.kind);
    try testing.expectEqual(@as(u8, '+'), plus.data.list.bullet);

    const ordered = root.children.items[2];
    try testing.expectEqual(document.Tag.list, ordered.tag);
    try testing.expectEqual(document.ListKind.ordered, ordered.data.list.kind);
    try testing.expectEqual(@as(u8, ')'), ordered.data.list.delimiter);
    try testing.expectEqual(@as(u32, 10), ordered.data.list.start);
    try testing.expectEqual(@as(usize, 2), ordered.children.items.len);

    var separated = try oliver.parse(testing.allocator, "- a\n\n+ b\n", .markdown, .{});
    defer separated.deinit();
    try testing.expectEqual(@as(usize, 2), separated.document.root.children.items.len);
    try testing.expect(!separated.document.root.children.items[0].data.list.loose);
    try testing.expect(!separated.document.root.children.items[1].data.list.loose);
}

test "markdown: nested lists use content indentation and loose state" {
    const oliver = @import("oliver.zig");
    var nested = try oliver.parse(testing.allocator, "- parent\n  - child\n    - grandchild\n", .markdown, .{});
    defer nested.deinit();

    const outer = nested.document.root.children.items[0];
    try testing.expectEqual(document.Tag.list, outer.tag);
    try testing.expect(!outer.data.list.loose);
    const outer_item = outer.children.items[0];
    try testing.expectEqual(document.Tag.list_item, outer_item.tag);
    try testing.expectEqual(document.Tag.paragraph, outer_item.children.items[0].tag);
    const middle = outer_item.children.items[1];
    try testing.expectEqual(document.Tag.list, middle.tag);
    const middle_item = middle.children.items[0];
    const inner = middle_item.children.items[1];
    try testing.expectEqual(document.Tag.list, inner.tag);
    try testing.expectEqualStrings("grandchild", inner.children.items[0].children.items[0].children.items[0].data.text);

    var loose = try oliver.parse(testing.allocator, "- a\n- b\n\n  c\n- d\n", .markdown, .{});
    defer loose.deinit();
    const list = loose.document.root.children.items[0];
    try testing.expectEqual(document.Tag.list, list.tag);
    try testing.expect(list.data.list.loose);
    const second = list.children.items[1];
    try testing.expectEqual(@as(usize, 2), second.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, second.children.items[0].tag);
    try testing.expectEqual(document.Tag.paragraph, second.children.items[1].tag);
}

test "markdown: blank-start and empty items stay distinct" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "-\n  first\n-\n- last\n", .markdown, .{});
    defer result.deinit();
    const list = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.list, list.tag);
    try testing.expectEqual(@as(usize, 3), list.children.items.len);
    try testing.expectEqual(@as(usize, 1), list.children.items[0].children.items.len);
    try testing.expectEqual(@as(usize, 0), list.children.items[1].children.items.len);
    try testing.expectEqual(@as(usize, 1), list.children.items[2].children.items.len);
}

// ---------------------------------------------------------------------------
// Markdown extensions (docs/MARKDOWN-EXTENSIONS.md): footnotes, definition
// lists, heading attribute lists, and GFM-style heading ids. All are opt-in
// through `Options`; the default frontend stays byte-exact CommonMark.
// ---------------------------------------------------------------------------

const ext_parse = struct {
    fn with(o: Options) oliver_options {
        return .{ .markdown = o };
    }
}.with;

const oliver_options = @import("oliver.zig").ParseOptions;

test "markdown: heading attribute lists consume trailing {#id .class} (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "## Exit codes {#exit-codes}\n", .markdown, ext_parse(.{ .heading_attributes = true }));
    defer result.deinit();

    const h = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.heading, h.tag);
    try testing.expectEqualStrings("exit-codes", h.data.heading.id.?);
    try testing.expectEqual(@as(?[]const u8, null), h.data.heading.class);
    // The IAL is consumed: the heading's inline text is just "Exit codes".
    try testing.expectEqual(@as(usize, 1), h.children.items.len);
    try testing.expectEqualStrings("Exit codes", h.children.items[0].data.text);
}

test "markdown: heading attribute lists combine id and class (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "## Custom heading id {#custom-showcase-id .showcase-heading}\n",
        .markdown,
        ext_parse(.{ .heading_attributes = true }),
    );
    defer result.deinit();

    const h = result.document.root.children.items[0];
    try testing.expectEqualStrings("custom-showcase-id", h.data.heading.id.?);
    try testing.expectEqualStrings("showcase-heading", h.data.heading.class.?);
}

test "markdown: heading attribute lists stay literal when disabled" {
    const oliver = @import("oliver.zig");
    // Default options: `{#id}` is ordinary heading text.
    var result = try oliver.parse(testing.allocator, "## Exit codes {#exit-codes}\n", .markdown, .{});
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqual(@as(?[]const u8, null), h.data.heading.id);
    try testing.expectEqual(@as(usize, 1), h.children.items.len);
    try testing.expectEqualStrings("Exit codes {#exit-codes}", h.children.items[0].data.text);
}

test "markdown: Setext heading attribute list (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "Setext heading {#setext-id}\n=========================\n",
        .markdown,
        ext_parse(.{ .heading_attributes = true }),
    );
    defer result.deinit();
    const h = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.heading, h.tag);
    try testing.expectEqual(@as(u8, 1), h.data.heading.level);
    try testing.expectEqualStrings("setext-id", h.data.heading.id.?);
}

test "markdown: footnotes collect definitions and references (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "Hi[^syntax] and more[^second].\n\n[^syntax]: First note body.\n[^second]: Second note body.\n",
        .markdown,
        ext_parse(.{ .footnotes = true }),
    );
    defer result.deinit();

    // Two definitions registered, in definition order.
    try testing.expectEqual(@as(usize, 2), result.document.footnotes.items.len);
    try testing.expectEqualStrings("syntax", result.document.footnotes.items[0].label);
    try testing.expectEqualStrings("second", result.document.footnotes.items[1].label);
    // Each definition owns a `.footnote` container with one paragraph.
    const f0 = result.document.footnotes.items[0].node;
    try testing.expectEqual(document.Tag.footnote, f0.tag);
    try testing.expectEqual(@as(usize, 1), f0.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, f0.children.items[0].tag);
    try testing.expectEqualStrings("First note body.", f0.children.items[0].children.items[0].data.text);

    // The body paragraph has two footnote refs (first-reference order).
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 5), p.children.items.len);
    try testing.expectEqual(document.Tag.footnote_ref, p.children.items[1].tag);
    try testing.expectEqualStrings("syntax", p.children.items[1].data.footnote_ref.label);
    try testing.expectEqual(document.Tag.footnote_ref, p.children.items[3].tag);
    try testing.expectEqualStrings("second", p.children.items[3].data.footnote_ref.label);
}

test "markdown: footnotes are literal text when disabled" {
    const oliver = @import("oliver.zig");
    // `[^note]:` is not a link reference definition (its "destination"
    // contains spaces), so with the extension disabled it is plain text.
    var result = try oliver.parse(
        testing.allocator,
        "Text[^note] here.\n\n[^note]: some note text with spaces\n",
        .markdown,
        .{},
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.document.footnotes.items.len);
    // The whole thing is ordinary paragraphs.
    try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
    try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[1].tag);
}

test "markdown: definition lists build dl/dt/dd structure (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "Term\n: Definition body.\n\nSatellite\n: First line.\n  Second line.\n",
        .markdown,
        ext_parse(.{ .definition_lists = true }),
    );
    defer result.deinit();

    const dl0 = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.definition_list, dl0.tag);
    try testing.expectEqual(@as(usize, 2), dl0.children.items.len);
    const dt0 = dl0.children.items[0];
    try testing.expectEqual(document.Tag.definition_term, dt0.tag);
    try testing.expectEqualStrings("Term", dt0.children.items[0].data.text);
    const dd0 = dl0.children.items[1];
    try testing.expectEqual(document.Tag.definition_body, dd0.tag);
    try testing.expectEqualStrings("Definition body.", dd0.children.items[0].children.items[0].data.text);

    const dl1 = result.document.root.children.items[1];
    try testing.expectEqual(document.Tag.definition_list, dl1.tag);
    const dd1 = dl1.children.items[1];
    // Two lines in the definition paragraph: a soft break between them.
    try testing.expectEqual(@as(usize, 3), dd1.children.items[0].children.items.len);
    try testing.expectEqual(document.Tag.soft_break, dd1.children.items[0].children.items[1].tag);
    try testing.expectEqualStrings("Second line.", dd1.children.items[0].children.items[2].data.text);
}

test "markdown: consecutive term/definition pairs merge into one dl (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "Term one\n: First.\nTerm two\n: Second.\n",
        .markdown,
        ext_parse(.{ .definition_lists = true }),
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.document.root.children.items.len);
    const dl = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.definition_list, dl.tag);
    try testing.expectEqual(@as(usize, 4), dl.children.items.len);
    try testing.expectEqualStrings("Term one", dl.children.items[0].children.items[0].data.text);
    try testing.expectEqualStrings("First.", dl.children.items[1].children.items[0].children.items[0].data.text);
    try testing.expectEqualStrings("Term two", dl.children.items[2].children.items[0].data.text);
    try testing.expectEqualStrings("Second.", dl.children.items[3].children.items[0].children.items[0].data.text);
}

test "markdown: definition lists are literal text when disabled" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "Term\n: Definition body.\n", .markdown, .{});
    defer result.deinit();
    // One ordinary paragraph containing both lines.
    try testing.expectEqual(document.Tag.paragraph, result.document.root.children.items[0].tag);
}

test "markdown: GFM strikethrough renders as deleted (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "~~Hi~~ Hello, world!",
        .markdown,
        ext_parse(.{ .strikethrough = true }),
    );
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    try testing.expectEqual(@as(usize, 2), p.children.items.len);
    try testing.expectEqual(document.Tag.deleted, p.children.items[0].tag);
    try testing.expectEqualStrings("Hi", p.children.items[0].children.items[0].data.text);
    try testing.expectEqualStrings(" Hello, world!", p.children.items[1].data.text);
}

test "markdown: strikethrough delimiters are exactly two tildes (extension)" {
    const oliver = @import("oliver.zig");
    // Single and triple tildes stay literal; two-tilde pairs strike.
    var result = try oliver.parse(
        testing.allocator,
        "~single~ ~~two~~ ~~~three~~~",
        .markdown,
        ext_parse(.{ .strikethrough = true }),
    );
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 3), p.children.items.len);
    try testing.expectEqualStrings("~single~ ", p.children.items[0].data.text);
    try testing.expectEqual(document.Tag.deleted, p.children.items[1].tag);
    try testing.expectEqualStrings(" ~~~three~~~", p.children.items[2].data.text);
}

test "markdown: strikethrough does not span paragraphs (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "This ~~has a\n\nnew paragraph~~.",
        .markdown,
        ext_parse(.{ .strikethrough = true }),
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.document.root.children.items.len);
    const p1 = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p1.tag);
    try testing.expectEqualStrings("This ~~has a", p1.children.items[0].data.text);
    const p2 = result.document.root.children.items[1];
    try testing.expectEqualStrings("new paragraph~~.", p2.children.items[0].data.text);
}

test "markdown: strikethrough is literal text when disabled" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "~~Hi~~", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    try testing.expectEqualStrings("~~Hi~~", p.children.items[0].data.text);
}

test "markdown: wikilinks parse into a .wikilink node with target and label (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "See [[Page Name]] and [[Page Name|Custom Label]] here.",
        .markdown,
        ext_parse(.{ .wikilinks = true }),
    );
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    try testing.expectEqual(@as(usize, 5), p.children.items.len);
    try testing.expectEqualStrings("See ", p.children.items[0].data.text);
    const w0 = p.children.items[1];
    try testing.expectEqual(document.Tag.wikilink, w0.tag);
    try testing.expectEqualStrings("Page Name", w0.data.wikilink.target);
    try testing.expectEqual(@as(?[]const u8, null), w0.data.wikilink.label);
    try testing.expectEqualStrings(" and ", p.children.items[2].data.text);
    const w1 = p.children.items[3];
    try testing.expectEqual(document.Tag.wikilink, w1.tag);
    try testing.expectEqualStrings("Page Name", w1.data.wikilink.target);
    try testing.expectEqualStrings("Custom Label", w1.data.wikilink.label.?);
    try testing.expectEqualStrings(" here.", p.children.items[4].data.text);
}

test "markdown: wikilinks are literal text when disabled" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, "See [[Page Name]] here.", .markdown, .{});
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.paragraph, p.tag);
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqualStrings("See [[Page Name]] here.", p.children.items[0].data.text);
}

test "markdown: wikilink malformed shapes stay literal (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "[[a|b|c]] [[]] [[|x]] [[x|]] [[ ]] [[unterminated",
        .markdown,
        ext_parse(.{ .wikilinks = true }),
    );
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 1), p.children.items.len);
    try testing.expectEqualStrings("[[a|b|c]] [[]] [[|x]] [[x|]] [[ ]] [[unterminated", p.children.items[0].data.text);
}

test "markdown: wikilink closer is greedy (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "[[a]]] b",
        .markdown,
        ext_parse(.{ .wikilinks = true }),
    );
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(@as(usize, 2), p.children.items.len);
    try testing.expectEqual(document.Tag.wikilink, p.children.items[0].tag);
    try testing.expectEqualStrings("a", p.children.items[0].data.wikilink.target);
    try testing.expectEqualStrings("] b", p.children.items[1].data.text);
}

test "markdown: wikilinks inside link text stay literal (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "A [b [[c]] d](/url) link",
        .markdown,
        ext_parse(.{ .wikilinks = true }),
    );
    defer result.deinit();
    const p = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.link, p.children.items[1].tag);
    const link = p.children.items[1];
    // Demoted to literal text — never a nested `<a>` (docs/WIKILINKS.md §2);
    // the contiguous text runs merge into one node.
    try testing.expectEqual(@as(usize, 1), link.children.items.len);
    try testing.expectEqual(document.Tag.text, link.children.items[0].tag);
    try testing.expectEqualStrings("b [[c]] d", link.children.items[0].data.text);
}

fn renderWikilinksHtml(input: []const u8, render_options: @import("oliver.zig").html.RenderOptions) !std.ArrayList(u8) {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, input, .markdown, ext_parse(.{ .wikilinks = true }));
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try oliver.html.render(testing.allocator, &aw.writer, &result.document, render_options);
    return aw.toArrayList();
}

test "markdown: wikilinks render with the default resolver (extension)" {
    var out = try renderWikilinksHtml("[[Page Name|Custom]] and [[Trimmed]]", .{});
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<p><a href=\"Page%20Name\">Custom</a> and <a href=\"Trimmed\">Trimmed</a></p>\n",
        out.items,
    );
}

fn testResolveWikilink(
    target: []const u8,
    label: ?[]const u8,
    ctx: ?*const anyopaque,
) @import("oliver.zig").html.ResolvedWikilink {
    _ = target;
    const n: u32 = if (ctx) |c| @as(*const u32, @ptrCast(@alignCast(c))).* else 0;
    return .{ .href = if (n == 1) "/notes" else "/none", .text = label orelse "untitled" };
}

test "markdown: a consumer wikilink resolver overrides href and text (extension)" {
    const ctx: u32 = 1;
    var out = try renderWikilinksHtml("[[Page Name|Custom]]", .{
        .wikilink_resolver = &testResolveWikilink,
        .wikilink_resolver_ctx = &ctx,
    });
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p><a href=\"/notes\">Custom</a></p>\n", out.items);
}

test "markdown: a 10,000-wikilink storm renders deterministically (extension)" {
    var input = std.ArrayList(u8).empty;
    defer input.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        if (i > 0) try input.append(testing.allocator, ' ');
        try input.appendSlice(testing.allocator, "[[Page ");
        const n0 = try std.fmt.allocPrint(testing.allocator, "{d}", .{i});
        try input.appendSlice(testing.allocator, n0);
        testing.allocator.free(n0);
        try input.appendSlice(testing.allocator, "|P");
        const n1 = try std.fmt.allocPrint(testing.allocator, "{d}", .{i});
        try input.appendSlice(testing.allocator, n1);
        testing.allocator.free(n1);
        try input.appendSlice(testing.allocator, "]]");
    }
    var a = try renderWikilinksHtml(input.items, .{});
    defer a.deinit(testing.allocator);
    var b = try renderWikilinksHtml(input.items, .{});
    defer b.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, a.items, b.items);
    try testing.expect(std.mem.count(u8, a.items, "<a href=\"Page%20") == 10_000);
}

test "markdown: callout parses type and title onto the blockquote (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "> [!note] Title here\n> Body line.\n",
        .markdown,
        ext_parse(.{ .callouts = true }),
    );
    defer result.deinit();
    const bq = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    try testing.expectEqualStrings("note", bq.data.block_quote.callout_type.?);
    try testing.expectEqualStrings("Title here", bq.data.block_quote.callout_title.?);
    // The title is inline-parsed into its own node list (docs/CALLOUTS.md §4).
    try testing.expectEqual(@as(usize, 1), bq.data.block_quote.callout_title_nodes.len);
    try testing.expectEqualStrings("Title here", bq.data.block_quote.callout_title_nodes[0].data.text);
    // The body is a normal paragraph inside the quote.
    try testing.expectEqual(@as(usize, 1), bq.children.items.len);
    try testing.expectEqual(document.Tag.paragraph, bq.children.items[0].tag);
    try testing.expectEqualStrings("Body line.", bq.children.items[0].children.items[0].data.text);
}

test "markdown: callout type is case-insensitive and trimmed (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "> [!TIP]\n> Do it.\n",
        .markdown,
        ext_parse(.{ .callouts = true }),
    );
    defer result.deinit();
    const bq = result.document.root.children.items[0];
    try testing.expectEqualStrings("tip", bq.data.block_quote.callout_type.?);
    // A titleless callout: no title source, no title nodes.
    try testing.expectEqual(@as(?[]const u8, null), bq.data.block_quote.callout_title);
    try testing.expectEqual(@as(usize, 0), bq.data.block_quote.callout_title_nodes.len);
}

test "markdown: callout title parses emphasis inlines (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "> [!warn] **Heads up**\n> Body.\n",
        .markdown,
        ext_parse(.{ .callouts = true }),
    );
    defer result.deinit();
    const bq = result.document.root.children.items[0];
    try testing.expectEqualStrings("warn", bq.data.block_quote.callout_type.?);
    const tn = bq.data.block_quote.callout_title_nodes;
    try testing.expectEqual(@as(usize, 1), tn.len);
    try testing.expectEqual(document.Tag.strong, tn[0].tag);
    try testing.expectEqualStrings("Heads up", tn[0].children.items[0].data.text);
}

test "markdown: malformed callout shapes stay literal (extension)" {
    const oliver = @import("oliver.zig");
    // No separator after `]`, empty type, and unclosed marker all stay
    // literal text inside an ordinary blockquote (docs/CALLOUTS.md §6).
    var result = try oliver.parse(
        testing.allocator,
        "> [!note]x\n> [!]\n> [!no close\n",
        .markdown,
        ext_parse(.{ .callouts = true }),
    );
    defer result.deinit();
    const bq = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    try testing.expectEqual(@as(?[]const u8, null), bq.data.block_quote.callout_type);
    // The three lines are one paragraph joined by soft breaks; the marker
    // bytes stay literal.
    const p = bq.children.items[0];
    try testing.expectEqual(@as(usize, 5), p.children.items.len);
    try testing.expectEqualStrings("[!note]x", p.children.items[0].data.text);
    try testing.expectEqualStrings("[!]", p.children.items[2].data.text);
    try testing.expectEqualStrings("[!no close", p.children.items[4].data.text);
}

test "markdown: callouts are off by default (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "> [!note] Title\n> Body.\n",
        .markdown,
        .{},
    );
    defer result.deinit();
    const bq = result.document.root.children.items[0];
    try testing.expectEqual(document.Tag.block_quote, bq.tag);
    try testing.expectEqual(@as(?[]const u8, null), bq.data.block_quote.callout_type);
    try testing.expectEqualStrings(
        "[!note] Title",
        bq.children.items[0].children.items[0].data.text,
    );
}

fn renderCalloutsHtml(input: []const u8) !std.ArrayList(u8) {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, input, .markdown, ext_parse(.{ .callouts = true }));
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
    return aw.toArrayList();
}

test "markdown: callout renders the div box, title, and body (extension)" {
    var out = try renderCalloutsHtml("> [!note] Title here\n> Body line.\n");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<div class=\"callout callout-note\">\n<div class=\"callout-title\">Title here</div>\n<p>Body line.</p>\n</div>\n",
        out.items,
    );
}

test "markdown: a titleless callout renders without the title div (extension)" {
    var out = try renderCalloutsHtml("> [!warning]\n> Body.\n");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<div class=\"callout callout-warning\">\n<p>Body.</p>\n</div>\n",
        out.items,
    );
}

fn renderSmartypantsHtml(input: []const u8) !std.ArrayList(u8) {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(testing.allocator, input, .markdown, ext_parse(.{ .smartypants = true }));
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
    return aw.toArrayList();
}

test "markdown: smartypants replaces quotes, dashes, and ellipses (extension)" {
    var out = try renderSmartypantsHtml("\"Hello,\" -- she said... And 2 x 4 is 8. (c) 2026, it's fine.\n");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<p>\u{201C}Hello,\u{201D} \u{2014} she said\u{2026} And 2 \u{00D7} 4 is 8. \u{00A9} 2026, it\u{2019}s fine.</p>\n",
        out.items,
    );
}

test "markdown: smartypants leaves braces literal (extension)" {
    // The Textile `{...}` character-macro table is Textile-only
    // (docs/SMARTY.md §1): a brace never expands under smartypants.
    var out = try renderSmartypantsHtml("A {c|} and {*} stay literal.\n");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p>A {c|} and {*} stay literal.</p>\n", out.items);
}

test "markdown: escaped quotes stay straight under smartypants (extension)" {
    // The escaped byte stays its own node and bypasses the pass, but the
    // renderer still HTML-escapes text payloads (docs/SMARTY.md §3).
    var out = try renderSmartypantsHtml("\\\"escaped\\\" and \\'single\\'.\n");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p>&quot;escaped&quot; and 'single'.</p>\n", out.items);
}

test "markdown: smartypants exempts code, autolinks, raw HTML tags, and payloads (extension)" {
    // Code spans, autolinks, raw HTML tags, and link/image src/title
    // never pass through the pass; text *between* tags is ordinary text
    // (matching Textile's model — the tag constructs are the exemption).
    var out = try renderSmartypantsHtml(
        "`code \"quotes\"` and <http://x.com/a--b> and <b title=\"a--b\">\"kept\"</b> and [link](</dest--x> \"title--y\") and ![alt \"quotes\"](/img.png \"t--t\").\n",
    );
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<p><code>code &quot;quotes&quot;</code> and <a href=\"http://x.com/a--b\">http://x.com/a--b</a> and <b title=\"a--b\">\u{201D}kept\u{201D}</b> and <a href=\"/dest--x\" title=\"title--y\">link</a> and <img src=\"/img.png\" alt=\"alt &quot;quotes&quot;\" title=\"t--t\" />.</p>\n",
        out.items,
    );
}

test "markdown: smartypants applies to link display text and scopes (extension)" {
    // Link display text is replaced (matching Textile); headings, table
    // cells, and callout titles/bodies are ordinary inline scopes.
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "# A \"heading\" -- bold\n\n[\"display\" -- text](/url)\n\n| \"cell\" |\n| --- |\n| body--x |\n\n> [!note] \"Title\" -- x\n> \"Body.\"\n",
        .markdown,
        ext_parse(.{ .smartypants = true, .callouts = true }),
    );
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<h1>A \u{201C}heading\u{201D} \u{2014} bold</h1>\n<p><a href=\"/url\">\u{201C}display\u{201D} \u{2014} text</a></p>\n<table>\n<thead>\n<tr>\n<th>\u{201C}cell\u{201D}</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>body\u{2014}x</td>\n</tr>\n</tbody>\n</table>\n<div class=\"callout callout-note\">\n<div class=\"callout-title\">\u{201C}Title\u{201D} \u{2014} x</div>\n<p>\u{201C}Body.\u{201D}</p>\n</div>\n",
        out.items,
    );
}

test "markdown: smartypants literal fallbacks (extension)" {
    // `---` -> em dash + hyphen; `....` -> ellipsis + period; unknown
    // fraction stays literal; letter-touching hyphens never en-dash;
    // a bare `x` stays an `x`.
    var out = try renderSmartypantsHtml("--- .... (1/3) foo-bar and 2x4 but x alone.\n");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<p>\u{2014}- \u{2026}. (1/3) foo-bar and 2\u{00D7}4 but x alone.</p>\n",
        out.items,
    );
}

test "markdown: smartypants is off by default (extension)" {
    const oliver = @import("oliver.zig");
    var result = try oliver.parse(
        testing.allocator,
        "\"Hello,\" -- she said.\n",
        .markdown,
        .{},
    );
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try oliver.html.render(testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p>&quot;Hello,&quot; -- she said.</p>\n", out.items);
}
