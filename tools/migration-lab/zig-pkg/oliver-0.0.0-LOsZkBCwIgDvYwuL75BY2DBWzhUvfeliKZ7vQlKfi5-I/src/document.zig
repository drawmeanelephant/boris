//! The normalized typed document model.
//!
//! Both dialects parse into this representation; the HTML renderer consumes
//! only this representation. See docs/DOCUMENT-MODEL.md for the design.
//!
//! Ownership: a `Document` owns an arena. All nodes are allocated from that
//! arena, and text payloads are slices *into the source bytes* (borrowed, not
//! copied). `Document.deinit` releases the arena in one step.
//!
//! Invariants:
//! - The root node is always a `.document` whose children are blocks.
//! - Block tags contain block or inline children as documented per tag;
//!   `thematic_break`, `code_block`, and `html_block` are childless leaves;
//!   `table` children are `table_row` blocks, `table_row` children are
//!   `table_cell` blocks, and `table_cell` children are inlines (a cell
//!   behaves like a paragraph: inline content only, no blocks).
//! - `emphasis`/`strong`/`bold`/`italic`/`deleted`/`inserted`/
//!   `superscript`/`subscript`/`span`/`link` contain inline children; the
//!   leaf inline tags (`text`, `code_span`, `image`, `autolink`, `raw_html`,
//!   `soft_break`, `hard_break`) never have children.
//! - `list` children are `list_item` blocks; `list_item` children are blocks.
//! - `Node.data.text` always points into the document's source bytes;
//!   `raw_html` reads its bytes by `Node.span` and carries no data payload;
//!   `data.code_span`, `data.code_block` (content/info), `data.html_block`,
//!   `data.image` (src/alt/title),
//!   `data.autolink` (href/label), and
//!   `data.link` (href/title) are the arena-owned (copied) payloads
//!   (see docs/DOCUMENT-MODEL.md invariant 9).

const std = @import("std");
const source = @import("source.zig");

/// Node kinds. Blocks and inlines are distinguished (see `Tag.isBlock`).
/// This set is deliberately small; see docs/DOCUMENT-MODEL.md for the
/// planned growth path.
pub const Tag = enum {
    /// Root of every document. Children: blocks.
    document,
    /// Paragraph. Children: inlines.
    paragraph,
    /// Heading. Children: inlines. `data.heading` is the level 1..6.
    heading,
    /// A thematic break (Markdown §4.1). Leaf block with no children or
    /// payload; renderers choose their own horizontal-rule serialization.
    thematic_break,
    /// A fenced or indented code block. Leaf block with no children;
    /// `data.code_block` holds normalized content and optional info string.
    code_block,
    /// A raw HTML block (Markdown §4.6). Leaf block with no children;
    /// `data.html_block` holds the verbatim container-stripped source lines
    /// (arena-owned — container prefixes make the block's source
    /// non-contiguous).
    html_block,
    /// A block quote (Markdown `>` markers, §5.1). Container: children are
    /// blocks. Span covers its lines' content with markers stripped.
    block_quote,
    /// A list (Markdown §5.3). Container: children are list items.
    /// `data.list` carries the type, ordered start, and tight/loose flag.
    /// Span covers its items' content lines.
    list,
    /// A list item (Markdown §5.2). Container: children are blocks.
    /// Span covers its content lines (marker stripped).
    list_item,
    /// A table (GFM §4.10 extension, Markdown frontend only). Container:
    /// children are `table_row` blocks — the first is the header row, the
    /// rest are body rows. `data.table` holds the per-column alignment.
    /// Span covers the header line through the last row line.
    table,
    /// One row of a `table` (GFM §4.10). Container: children are
    /// `table_cell` blocks. No payload: the row's role (header vs body)
    /// is its position under the table, and each cell carries its own
    /// header/alignment flags.
    table_row,
    /// One cell of a `table_row` (GFM §4.10). Container: children are
    /// inlines. `data.table_cell` carries the header flag and the column
    /// alignment (resolved at parse time so the renderer never indexes
    /// across nodes).
    table_cell,
    /// Plain text. `data.text` is a slice of the source.
    text,
    /// Emphasized inline content (Markdown `*x*`, `_x_`; Textile `_x_`).
    /// Children: inlines.
    emphasis,
    /// Strongly emphasized inline content (Markdown `**x**`, `__x__`; Textile
    /// `*x*`). Children: inlines.
    strong,
    /// Bold inline content (Textile `**x**`). Children: inlines. Textile
    /// distinguishes bold `**x**` → `<b>` from strong `*x*` → `<strong>`;
    /// Markdown has no bold tag.
    bold,
    /// Italic inline content (Textile `__x__`). Children: inlines. Textile
    /// distinguishes italic `__x__` → `<i>` from emphasis `_x_` → `<em>`;
    /// Markdown has no italic tag.
    italic,
    /// Deleted inline content (Textile `-x-`). Children: inlines.
    deleted,
    /// Inserted inline content (Textile `+x+`). Children: inlines.
    inserted,
    /// Bigger inline content (Textile `++x++`). Children: inlines.
    big,
    /// Smaller inline content (Textile `--x--`). Children: inlines.
    small,
    /// Superscript inline content (Textile `^x^`). Children: inlines.
    superscript,
    /// Subscript inline content (Textile `~x~`). Children: inlines.
    subscript,
    /// Cited inline content (Textile `??x??`, Hobix "Use double question
    /// marks to indicate citation"). Children: inlines. Like the other
    /// phrase tags it can carry Textile phrase attributes (T21).
    cite,
    /// A generic inline span (Textile `%x%`). Children: inlines. The
    /// attribute-bearing forms (`%{style}(class#id)[lang]x%`) carry their
    /// composed attrs in `data.span` (Hobix "Phrase Attributes").
    span,
    /// Inline code (Markdown backtick span; Textile `@x@`). No
    /// children; `data.code_span` is the normalized content, one of the text
    /// payloads owned by the document arena rather than borrowed from the
    /// source (newlines become spaces, so it cannot be a source slice).
    code_span,
    /// An inline link (Markdown `[text](dest "title")`; Textile `"text":
    /// url` planned). Children: inlines (the link text). `data.link` holds
    /// the arena-owned, escape-resolved href and optional title.
    link,
    /// An inline image (Markdown `![alt](src "title")`; Textile
    /// `!url(alt)!` planned). Leaf: no children. `data.image` holds the
    /// arena-owned src, the flattened plain-string alt, and the optional
    /// title (docs/IMAGES-PARSING.md §3: the description's inlines are
    /// flattened to a string at parse time; the image node carries no
    /// subtree).
    image,
    /// An autolink (Markdown `<scheme:...>` or `<user@host>`, §6.5). Leaf:
    /// no children. `data.autolink` holds the arena-owned href (the raw
    /// URI, or `mailto:` + the email) and the label (the raw content
    /// verbatim — backslash escapes are inert inside autolinks, so unlike
    /// `data.link` this payload is *not* escape-resolved;
    /// docs/AUTOLINKS.md §3).
    autolink,
    /// An inline wikilink (Markdown `[[target]]` / `[[target|label]]`
    /// extension). Leaf: no children. `data.wikilink` holds the trimmed
    /// target and optional label — both source slices (the trimmed span
    /// borrows the source; docs/WIKILINKS.md §4). Resolution is a
    /// renderer policy: the default percent-encodes the target as the
    /// href with `label orelse target` as the text.
    wikilink,
    /// A raw HTML tag (Markdown §6.6): an open/closing tag, comment,
    /// processing instruction, declaration, or CDATA section. Leaf: no
    /// children. No data payload — the renderer writes the source bytes
    /// of `node.span` verbatim, without escaping (docs/RAW-HTML.md §3).
    raw_html,
    /// A line break that renders as a newline in HTML (Markdown soft break).
    soft_break,
    /// A line break that renders as `<br />` in HTML (Markdown hard break,
    /// Textile line break).
    hard_break,
    /// A Textile footnote reference `[N]`: renders as
    /// `<sup class="footnote"><a href="#fnN">N</a></sup>` (Textile 2
    /// "Footnotes"). Leaf: the payload is the footnote number.
    footnote_ref,
    /// A Textile acronym `CSS(Cascading Style Sheets)` (Hobix
    /// "Acronyms"): renders `<acronym title="…">CSS</acronym>`. Leaf:
    /// `data.acronym` holds the letters and the definition title.
    acronym,
    /// A Markdown definition list (Pandoc-style extension): container whose
    /// children are alternating `.definition_term` and `.definition_body`
    /// nodes, rendered as `<dl><dt>…</dt><dd>…</dd>…</dl>`.
    definition_list,
    /// A definition list term: container whose children are inlines (like a
    /// heading).
    definition_term,
    /// A definition list body: container whose children are blocks (the
    /// definition content).
    definition_body,
    /// A footnote definition body (Markdown `[^label]:` extension): a
    /// container whose children are blocks. Never a document child — the
    /// renderer emits it inside the footnotes section.
    footnote,

    pub fn isBlock(self: Tag) bool {
        return switch (self) {
            .document, .paragraph, .heading, .thematic_break, .code_block, .html_block, .block_quote, .list, .list_item, .table, .table_row, .table_cell, .definition_list, .definition_term, .definition_body, .footnote => true,
            .text, .emphasis, .strong, .bold, .italic, .deleted, .inserted, .big, .small, .superscript, .subscript, .cite, .span, .code_span, .link, .image, .autolink, .wikilink, .raw_html, .soft_break, .hard_break, .footnote_ref, .acronym => false,
        };
    }

    pub fn isInline(self: Tag) bool {
        return switch (self) {
            .text, .emphasis, .strong, .bold, .italic, .deleted, .inserted, .big, .small, .superscript, .subscript, .cite, .span, .code_span, .link, .image, .autolink, .wikilink, .raw_html, .soft_break, .hard_break, .footnote_ref, .acronym => true,
            .document, .paragraph, .heading, .thematic_break, .code_block, .html_block, .block_quote, .list, .list_item, .table, .table_row, .table_cell, .definition_list, .definition_term, .definition_body, .footnote => false,
        };
    }
};

/// Per-tag payload. Only the field matching the tag is meaningful.
pub const Data = union(enum) {
    none,
    /// `.paragraph`: the Textile block attributes (`p(...).`/`p{...}.`
    /// signatures), empty for plain paragraphs. Markdown paragraphs carry
    /// none.
    paragraph: Paragraph,
    /// `.block_quote`: the Textile block attributes (`bq(...).`/`bq{...}.`
    /// signatures), empty for plain quotes. Markdown quotes carry none.
    block_quote: BlockQuote,
    /// `.heading`: level, 1..6, plus the Textile block attributes
    /// (`hN(...).`/`hN{...}.` signatures); Markdown headings carry none.
    heading: Heading,
    /// `.footnote_ref`: the footnote reference payload. Textile `[N]`
    /// references carry a `number`; Markdown `[^label]` references carry
    /// the label (numbered at render time in first-reference order).
    footnote_ref: FootnoteRef,
    /// `.acronym`: the Textile acronym (`CSS(Cascading Style Sheets)`, Hobix
    /// "Acronyms"): the uppercase letters (a source slice, verbatim) and
    /// the definition as the `title` (arena-owned, like link/image
    /// titles). Markdown never produces acronym nodes.
    acronym: Acronym,
    /// `.text`: borrowed slice of the document source.
    text: []const u8,
    /// `.code_span`: normalized content. Arena-owned copy (not a source
    /// slice) because line endings are converted to spaces; see the
    /// ownership note in the module comment and docs/DOCUMENT-MODEL.md.
    code_span: []const u8,
    /// `.code_block`: normalized literal content and optional trimmed,
    /// escape-resolved info string. Both are arena-owned because content
    /// line endings/indentation and info-string escapes (and entity
    /// references, §2.5) are normalized.
    code_block: CodeBlock,
    /// `.html_block`: the verbatim container-stripped source lines of the
    /// block. Arena-owned because container prefixes are stripped (the
    /// lines are not contiguous in the source).
    html_block: []const u8,
    /// `.link`: escape-resolved destination and optional title, both
    /// arena-owned copies (backslash escapes do not survive as source
    /// slices). The title is null when absent, not an empty string.
    link: Link,
    /// `.image`: escape-resolved src and optional title (like `link`),
    /// plus the flattened plain-string alt. All arena-owned copies; the
    /// alt is the description's inlines flattened per §6.4 (see
    /// docs/IMAGES-PARSING.md §3), so it cannot be a source slice. The
    /// title is null when absent, not an empty string. Textile image
    /// modifiers (width/height/attrs) are arena-owned too.
    image: Image,
    /// `.autolink`: the href and label, both arena-owned copies of the
    /// raw autolink content. Unlike `link`, backslash escapes are inert
    /// inside autolinks (§6.5), so the content is copied verbatim — never
    /// passed through escape resolution (docs/AUTOLINKS.md §3).
    autolink: Autolink,
    /// `.wikilink`: the trimmed target and optional label of a
    /// `[[target]]` / `[[target|label]]` wikilink (Markdown extension),
    /// both source slices (trimming narrows the span; no copy).
    wikilink: Wikilink,
    /// `.list`: the list's type, its bullet character or ordered delimiter,
    /// the ordered start number (1 for bullet lists; the first item's number
    /// for ordered), and the tight/loose flag (docs/BLOCKS-PARSING.md §4:
    /// loose iff any item pair is separated by a blank line or any item
    /// directly contains two blocks separated by one). `.definition` is the
    /// Textile `dl.` list.
    list: List,
    /// `.list_item`: the term/definition role of a Textile definition-list
    /// item (`dl.`, Textile 2); plain list items keep `.none`.
    list_item: ListItem,
    /// `.table`: the per-column alignment, in order, one entry per column
    /// (GFM §4.10: from the delimiter row; Textile: from the header row),
    /// plus optional Textile table attributes.
    table: Table,
    /// `.table_row`: the row's optional Textile attributes.
    table_row: TableRow,
    /// `.table_cell`: the header flag, the column alignment (GFM), the
    /// Textile colspan/rowspan, and the cell's Textile attributes,
    /// resolved at parse time so the renderer never indexes across nodes.
    table_cell: TableCell,
    /// `.span`: the Textile phrase attributes (`%{style}(class#id)[lang]x%`,
    /// Hobix "Phrase Attributes"), empty for a plain span. Markdown never
    /// produces span nodes.
    span: Span,
    /// `.phrase`: the Textile phrase attributes on a non-span phrase node
    /// (`*{style}x*`, `_(class)x_`, …), written on the phrase's own tag.
    /// Markdown phrase nodes keep `.none` and render without attrs.
    phrase: Phrase,
};

/// The payload of a `.span` node: the Textile phrase attributes in the
/// fixed render order (style/class/id/lang; docs/TEXTILE-PARITY.md §18).
pub const Span = struct {
    attrs: []const Attribute = &.{},
};

/// The payload of a `.acronym` node (Hobix "Acronyms"): the uppercase
/// letters — a verbatim source slice — and the parenthesized definition
/// as the `title` attribute (arena-owned, like link/image titles). The
/// definition is opaque: no phrase formatting, no character replacements.
pub const Acronym = struct {
    text: []const u8,
    title: []const u8,
};

/// The payload of a non-span phrase node (`*x*`, `_x_`, `-x-`, …) that
/// carries Textile phrase attributes: the composed attrs in the fixed
/// render order, written on the phrase's own HTML tag
/// (`*{color:red}x*` → `<strong style="color:red;">`, Hobix "Phrase
/// Attributes"). Markdown phrase nodes carry `.none` instead and render
/// without attrs.
pub const Phrase = struct {
    attrs: []const Attribute = &.{},
};

/// The payload of a `.paragraph` node: the Textile block attributes in the
/// fixed render order (style/class/id/lang; docs/TEXTILE-PARITY.md §8).
pub const Paragraph = struct {
    attrs: []const Attribute = &.{},
};

/// The payload of a `.block_quote` node: the Textile block attributes and
/// an optional citation URL (`bq.:URL`, the current Textile docs' citation
/// form), emitted as the `cite` attribute. `cite` is arena-owned; Markdown
/// never sets it.
pub const BlockQuote = struct {
    attrs: []const Attribute = &.{},
    cite: ?[]const u8 = null,
    /// Callout (extension, docs/CALLOUTS.md): the normalized lowercase
    /// type (`[!NOTE]` → `note`), an arena-owned copy; null for ordinary
    /// blockquotes. Markdown sets it; Textile never does.
    callout_type: ?[]const u8 = null,
    /// The callout title's raw source bytes — the first content line's
    /// remainder after `[!type] `, trimmed; null when there is no title.
    /// Borrowed source slice.
    callout_title: ?[]const u8 = null,
    /// The title's inline-parsed nodes, arena-owned (`callout_title` is
    /// the source; these are the parsed form, so emphasis/wikilinks work
    /// in titles). Empty for ordinary blockquotes and titleless callouts.
    callout_title_nodes: []*Node = &.{},
};

/// The payload of a `.heading` node: the level (1..6) and the Textile
/// block attributes, plus the optional Markdown heading-attribute-list
/// (IAL) `id` and `class` (`## Heading {#id .class}` extension). When
/// `heading_ids` rendering is enabled, an absent explicit `id` is replaced
/// by the GFM-style slug of the heading's text.
pub const Heading = struct {
    level: u8,
    attrs: []const Attribute = &.{},
    /// Markdown IAL `{#id}`; null when absent. Raw source slice (escapes
    /// and entities are not resolved).
    id: ?[]const u8 = null,
    /// Markdown IAL `{.class}`; null when absent. Raw source slice.
    class: ?[]const u8 = null,
};

/// The payload of a `.footnote_ref` node.
pub const FootnoteRef = struct {
    /// Markdown `[^label]` reference label, or empty for a Textile `[N]`
    /// reference. The renderer numbers Markdown references in
    /// first-reference order.
    label: []const u8 = "",
    /// Textile footnote number (`[N]`, rendered directly). Unused for
    /// Markdown references.
    number: u16 = 0,
};

/// A Markdown footnote definition (`[^label]:` extension): the (exact,
/// case-sensitive) label and the `.footnote` container node holding the
/// definition's blocks. Definitions never appear in the document body;
/// they are registered here and rendered at the end of the document when
/// the `footnotes` render option is enabled.
pub const FootnoteDef = struct {
    label: []const u8,
    node: *Node,
};

/// The payload of a `.code_block` leaf. `content` uses `\n` line endings and
/// includes one newline for every source content line. `info` is the complete
/// trimmed, escape-resolved fence info string, or null when absent; renderers
/// may interpret it. `escape` selects the Textile `pre.` verbatim form (no
/// escaping, no `<code>` wrapper); Markdown and Textile `bc.` keep the
/// default. `attrs` are the Textile block-attribute modifiers (`bc{...}.`),
/// emitted on the `<pre>` element; Markdown carries none.
pub const CodeBlock = struct {
    content: []const u8,
    /// The complete trimmed, escape-resolved fence info string, or null when
    /// absent; renderers may interpret it.
    info: ?[]const u8 = null,
    /// Textile `pre.` renders the content verbatim inside `<pre>`; when
    /// true (Markdown fenced/indented and Textile `bc.`) the content is
    /// escaped inside `<pre><code>`.
    escape: bool = true,
    /// Textile block-attribute modifiers, emitted on the `<pre>` element.
    attrs: []const Attribute = &.{},
};

/// `.autolink` payload: the raw content between `<` and `>`, verbatim
/// (escapes inert), plus the href it expands to. For a URI autolink the
/// href is the content itself; for an email autolink it is `mailto:` +
/// the content. Both are arena-owned copies (the `mailto:` prefix cannot
/// be a source slice).
pub const Autolink = struct {
    href: []const u8,
    label: []const u8,
};

/// `.wikilink` payload: the trimmed target and the optional trimmed
/// label of a `[[target]]` / `[[target|label]]` wikilink (Markdown
/// extension, docs/WIKILINKS.md). Both are source slices — trimming
/// narrows the span, so no copy is needed. The label is null when the
/// `|label` form is absent, not an empty string. The node span covers
/// the whole `[[…]]` construct.
pub const Wikilink = struct {
    target: []const u8,
    label: ?[]const u8 = null,
};

/// The payload of a `.list` node (Markdown §5.3). `bullet`/`delimiter`
/// are what define "same type" for merging adjacent items: same bullet
/// character, or same ordered delimiter (`.` vs `)`). `.definition` is
/// the Textile `dl.` definition list (Textile 2 "Definition lists");
/// its items carry their term/definition role in `data.list_item` and
/// render `<dl>`/`<dt>`/`<dd>` (docs/TEXTILE-PARITY.md §21).
pub const ListKind = enum { bullet, ordered, definition };

pub const List = struct {
    /// Bullet, ordered, or Textile definition list.
    kind: ListKind,
    /// For `.bullet`: the marker character (`-`, `+`, or `*`).
    bullet: u8 = 0,
    /// For `.ordered`: the delimiter (`.` or `)`).
    delimiter: u8 = 0,
    /// For `.ordered`: the start number (its first item's number).
    /// Always 1 for bullet lists.
    start: u32 = 1,
    /// Tight (false) vs loose (true). Paragraphs directly in a tight
    /// list's items render without `<p>`.
    loose: bool = false,
    /// Textile block attributes from a `dl<mods>.` signature, on the
    /// `<dl>` element; Markdown lists carry none.
    attrs: []const Attribute = &.{},
};

/// The role of a Textile definition-list item: the term (`<dt>`) or its
/// definition (`<dd>`).
pub const ListItemRole = enum { term, definition };

/// The payload of a `.list_item` node in a Textile definition list: the
/// item's role, so the renderer writes `<dt>`/`<dd>` instead of `<li>`.
/// Plain (Markdown and Textile bullet/ordered) list items keep `.none`.
pub const ListItem = struct {
    role: ListItemRole = .term,
};

/// Column alignment of a GFM table (§4.10), from the delimiter row:
/// `---` unaligned, `:---` left, `---:` right, `:---:` center. `none`
/// renders without an `align` attribute. `justify` is the Textile `<>`
/// modifier (full justification); GFM never produces it, and Textile
/// renders its alignment through CSS styles rather than the `align`
/// attribute, so it only appears in table-level metadata.
pub const TableAlign = enum {
    none,
    left,
    center,
    right,
    justify,
};

/// One cell/row/table attribute (Textile): a fixed-name/value pair in the
/// documented render order `style`, `class`, `id`, `lang`. The `style`
/// value is the complete composed style string (user rule + padding +
/// text-align + vertical-align, joined with `; `); all values are
/// arena-owned copies (Textile normalizes them, so they cannot borrow the
/// source). GFM tables carry no attributes.
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// The payload of a `.table` node: the per-column alignment, one entry
/// per column, in column order (GFM §4.10: from the delimiter row; Textile
/// tables: from the header row, the source of the column-default
/// propagation rule). The column count is `alignment.len`; GFM body rows
/// pad or truncate their cells to it. `attrs` holds Textile table
/// attributes (`table{...}.`/`table(...).` signatures). `sections` selects
/// the HTML structure: GFM tables render with `<thead>`/`<tbody>` sections
/// (row 0 is the header row), while Textile tables render as flat `<tr>`
/// rows — the Textile references show no thead/tbody even with header
/// cells (docs/TEXTILE-PARITY.md §7).
pub const Table = struct {
    alignment: []const TableAlign,
    attrs: []const Attribute = &.{},
    sections: bool = false,
};

/// The payload of a `.table_row` node: the Textile row attributes
/// (`{style}`, `(class)`, `(#id)`, `[lang]`, padding, `^`/`~` valign — all
/// composed into the row's `style` where applicable). GFM rows carry no
/// attributes.
pub const TableRow = struct {
    attrs: []const Attribute = &.{},
};

/// The payload of a `.table_cell` node: `header` selects `<th>` vs
/// `<td>`, `alignment` selects the optional `align` attribute (GFM),
/// `colspan`/`rowspan` (Textile `\n`/`/n` modifiers, 1 when absent), and
/// `attrs` holds the Textile cell attributes (`{style}`, `(class)`,
/// `(#id)`, `[lang]`, padding, and the `<`/`>`/`=`/`<>`/`^`/`~` alignment
/// modifiers — all resolved at parse time into the cell's `style`). All
/// are resolved at parse time from the row's position and the table's
/// column alignment, so rendering needs no cross-node lookup.
pub const TableCell = struct {
    header: bool,
    alignment: TableAlign,
    colspan: u8 = 1,
    rowspan: u8 = 1,
    attrs: []const Attribute = &.{},
};

/// The payload of a `.image` node: the resolved src, the flattened
/// plain-string alt (always present, possibly empty — the spec's `alt=""`
/// for `![](/url)`), and the optional title. `src` and `title` are
/// escape-resolved like `link.href`/`link.title`; percent-encoding of the
/// src is a renderer policy shared with href (docs/ARCHITECTURE.md). The
/// alt is the plain string content of the image description (no
/// formatting) and is HTML-escaped at render like text.
pub const Image = struct {
    src: []const u8,
    alt: []const u8,
    title: ?[]const u8,
    /// Textile image modifiers (T18): optional width/height, each a
    /// dimension (`10`) or percentage (`20%`) string, and the
    /// block-attribute-style modifier list (style/class/id, the composed
    /// alignment/padding folded into the style) — from the Textile 2
    /// sizing forms and the `!<x!`/`!{style}x!`/`!(class)x!` modifier
    /// run. Markdown never sets them (both stay null/empty).
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    attrs: []const Attribute = &.{},
};

/// The payload of a `.link` node: the resolved href and optional title.
/// Both are arena-owned copies of source ranges with backslash escapes
/// applied (§6.3: "with backslash-escapes in effect as described above").
/// Percent-encoding of the href is a renderer policy (spec: "Renderers may
/// make different decisions about how to escape or normalize URLs"), so the
/// model stores the plain resolved URI.
pub const Link = struct {
    href: []const u8,
    title: ?[]const u8,
};

pub const Node = struct {
    tag: Tag,
    span: source.Span,
    data: Data = .none,
    children: std.ArrayList(*Node) = .empty,

    pub fn isBlock(self: *const Node) bool {
        return self.tag.isBlock();
    }

    pub fn isInline(self: *const Node) bool {
        return self.tag.isInline();
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    /// Borrowed input; text payloads slice into it.
    src: source.Source,
    root: *Node,
    /// Markdown footnote definitions, in definition order. Arena-owned;
    /// the arena reset releases them with everything else.
    footnotes: std.ArrayList(FootnoteDef) = .empty,

    pub fn init(backing: std.mem.Allocator, src: source.Source) !Document {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const root = try arena.allocator().create(Node);
        root.* = .{
            .tag = .document,
            .span = .{ .start = 0, .end = @intCast(src.bytes.len) },
        };
        return .{ .arena = arena, .src = src, .root = root };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// Allocator for this document's arena; the only allocator nodes use.
    pub fn allocator(self: *Document) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Creates a node owned by the document's arena.
    pub fn createNode(
        self: *Document,
        tag: Tag,
        span: source.Span,
        data: Data,
    ) !*Node {
        const node = try self.arena.allocator().create(Node);
        node.* = .{ .tag = tag, .span = span, .data = data };
        return node;
    }

    pub fn appendChild(self: *Document, parent: *Node, child: *Node) !void {
        try parent.children.append(self.arena.allocator(), child);
    }

    /// Source bytes covered by a span.
    pub fn text(self: *const Document, span: source.Span) []const u8 {
        return self.src.bytes[span.start..span.end];
    }

    /// Pre-order (document order) traversal. Deterministic: a parent is
    /// yielded before its children, and children are yielded in append order.
    /// Uses an explicit stack, so traversal depth does not consume the call
    /// stack — important for untrusted, deeply nested documents.
    pub const Iterator = struct {
        arena: std.mem.Allocator,
        stack: std.ArrayList(*Node) = .empty,

        pub fn init(arena: std.mem.Allocator, root: *Node) !Iterator {
            var self = Iterator{ .arena = arena };
            try self.stack.append(arena, root);
            return self;
        }

        pub fn next(self: *Iterator) !?*Node {
            const node = self.stack.pop() orelse return null;
            var i = node.children.items.len;
            while (i > 0) {
                i -= 1;
                try self.stack.append(self.arena, node.children.items[i]);
            }
            return node;
        }

        pub fn deinit(self: *Iterator) void {
            self.stack.deinit(self.arena);
        }
    };
};

test "document: creation, spans, deterministic pre-order traversal" {
    const src = source.Source{ .bytes = "# hi" };
    var doc = try Document.init(std.testing.allocator, src);
    defer doc.deinit();

    const h = try doc.createNode(.heading, .{ .start = 0, .end = 4 }, .{ .heading = .{ .level = 1 } });
    const t = try doc.createNode(.text, .{ .start = 2, .end = 4 }, .{ .text = "hi" });
    try doc.appendChild(h, t);
    try doc.appendChild(doc.root, h);

    var it = try Document.Iterator.init(std.testing.allocator, doc.root);
    defer it.deinit();
    try std.testing.expectEqual(Tag.document, (try it.next()).?.tag);
    try std.testing.expectEqual(Tag.heading, (try it.next()).?.tag);
    try std.testing.expectEqual(Tag.text, (try it.next()).?.tag);
    try std.testing.expectEqual(@as(?*Node, null), try it.next());
}

test "document: text payloads borrow the source" {
    const src = source.Source{ .bytes = "hello world" };
    var doc = try Document.init(std.testing.allocator, src);
    defer doc.deinit();
    const t = try doc.createNode(.text, .{ .start = 6, .end = 11 }, .{ .text = doc.text(.{ .start = 6, .end = 11 }) });
    try std.testing.expectEqualStrings("world", t.data.text);
    // The payload aliases the source slice rather than copying it.
    try std.testing.expect(t.data.text.ptr == src.bytes.ptr + 6);
}
