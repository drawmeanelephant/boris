//! Deterministic HTML rendering from the normalized document model.
//!
//! Rendering depends only on the document, never on the dialect that produced
//! it, and never reparses source. See docs/ARCHITECTURE.md ("HTML output
//! policy") for the explicit policies this renderer follows:
//!
//! - Text is escaped: `&` `&amp;`, `<` `&lt;`, `>` `&gt;`, `"` `&quot;`;
//!   NUL (U+0000) is emitted as U+FFFD.
//! - Link attributes: `href` is percent-encoded (a deliberate, documented
//!   policy derived from the spec examples: encode everything except
//!   alphanumerics and `-_.~!*'(),;:&=+$#@/%?`) and then HTML-escaped;
//!   `title` is HTML-escaped without percent-encoding. Attributes are
//!   emitted in the fixed order `href` then `title`, in double quotes.
//! - Images render as a void element `<img src="..." alt="..."
//!   title="..." />` under `void_trailing_slash`. `src` uses the same
//!   percent-encoding + HTML-escaping policy as `href`; `alt` is always
//!   emitted (possibly empty) and HTML-escaped like text; `title` only
//!   when present. Attribute order is fixed: `src`, `alt`, `title`.
//! - Headings use the level 1..6 (clamped for hand-built documents).
//! - Code spans render `<code>...</code>` with the same escaping as text.
//! - Code blocks render `<pre><code>...</code></pre>`; the first word of an
//!   info string becomes an escaped `language-...` class.
//! - Raw HTML leaves write their source spans verbatim, without escaping;
//!   this is the one inline form whose bytes can include source line endings.
//! - Lists render as `<ul>`/`<ol>` with `<li>` children; tight-list direct
//!   paragraphs omit `<p>`, while loose-list paragraphs retain it.
//! - Thematic breaks render as `<hr />` by default (or `<hr>` when the void
//!   trailing-slash option is disabled).
//! - Tables (GFM §4.10) render `<table>` with `<thead>` and `<tbody>`
//!   sections; the first row is the header (`<th>`), the rest body
//!   (`<td>`). Aligned columns carry an `align` attribute
//!   (left/center/right). `<tbody>` is omitted when the table has no body
//!   rows. Cells render inline content like a paragraph.
//! - Generated line endings in output are always `\n`; raw HTML source spans
//!   retain their original line-ending bytes by design.
//! - Every block-level element is followed by exactly one `\n`, so nonempty
//!   output always ends with `\n`.
//! - Void elements are emitted as `<br />` by default (CommonMark reference
//!   style), toggleable via `RenderOptions`.
//!
//! ## Output profiles
//!
//! The same traversal implements two deterministic serialization profiles
//! (one IR, one semantics, different bytes):
//!
//! - `.html` (default): today's HTML serialization, including the raw-HTML
//!   passthrough policy below.
//! - `.xhtml`: XML-compatible XHTML fragment serialization. Void elements
//!   always use the XML empty-element form (`<br />`, `<hr />`, `<img ... />`)
//!   regardless of `void_trailing_slash`; text and attribute escaping already
//!   satisfies XML (the four predefined escapes plus U+FFFD for NUL, with
//!   raw Unicode preserved). No document wrapper, namespace declaration, or
//!   DOCTYPE is added: this serializes the same fragment.
//!
//! The XHTML profile is fail-closed on verbatim content: `.raw_html` leaves,
//! `.html_block` leaves, and Textile `pre.` code blocks (`escape == false`)
//! pass source bytes through unchanged, which cannot be guaranteed
//! XML-well-formed. Rendering such a document through `.xhtml` fails with
//! `error.RawHtmlNotXmlWellFormed`; Oliver never rewrites, escapes, or
//! reparses that content in XHTML mode. See docs/XHTML.md.
//!
//! Traversal uses an explicit stack rather than recursion, so rendering a
//! hostile, deeply nested document cannot overflow the call stack.

const std = @import("std");
const document = @import("document.zig");
const entities = @import("entities.zig");

/// The serializer output profile. Both profiles consume the same normalized
/// document and differ only in serialization bytes (docs/XHTML.md).
pub const OutputProfile = enum {
    html,
    xhtml,
};

/// The result of a wikilink resolution (docs/WIKILINKS.md §5): the href
/// and the visible text. Memory must outlive the render call (the caller's
/// arena or static data); the renderer never frees it.
pub const ResolvedWikilink = struct {
    href: []const u8,
    text: []const u8,
};

/// A wikilink resolver: a pure function of (target, label, ctx) with no
/// hidden state, passed an opaque context value (the freestanding core has
/// no closures). See `RenderOptions.wikilink_resolver`.
pub const WikilinkResolver = *const fn (target: []const u8, label: ?[]const u8, ctx: ?*const anyopaque) ResolvedWikilink;

pub const RenderOptions = struct {
    /// Emit void elements with a trailing slash (`<br />`) instead of the
    /// HTML5 form (`<br>`). Defaults to the CommonMark reference style.
    /// Ignored under `.xhtml`, where voids always use the XML form.
    void_trailing_slash: bool = true,
    /// The output profile: `.html` (default) or `.xhtml`.
    profile: OutputProfile = .html,
    /// Emit GFM-style auto-generated `id` attributes on headings (the
    /// Markdown `heading_ids` extension, docs/MARKDOWN-EXTENSIONS.md): a
    /// heading without an explicit IAL id gets a slug of its plain-text
    /// content (lowercased ASCII, non-word bytes dropped, whitespace runs
    /// collapsed to `-`, leading/trailing `-` trimmed). Off by default so
    /// the CommonMark corpus stays byte-exact.
    heading_ids: bool = false,
    /// Render Markdown footnotes (the `footnotes` parse extension): each
    /// `[^label]` reference becomes a footnote-ref link numbered in
    /// first-reference order, and a `<section class="footnotes">` block is
    /// appended at the end of the document with the used definitions and
    /// their back-references. Off by default.
    footnotes: bool = false,
    /// Resolve `.wikilink` nodes (the `wikilinks` parse extension,
    /// docs/WIKILINKS.md §5). Null uses the default policy: the href is
    /// the target through the standard href percent-encoding and the text
    /// is `label orelse target`. A resolver is a pure function of its
    /// inputs and returns memory that outlives the render call.
    wikilink_resolver: ?WikilinkResolver = null,
    /// The opaque context passed unchanged to `wikilink_resolver`.
    wikilink_resolver_ctx: ?*const anyopaque = null,
};

/// Footnote rendering context: label → number (first-reference order) and
/// the used labels in that order. Built by a pre-pass over the document
/// when the `footnotes` render option is enabled.
const Footnotes = struct {
    numbers: std.StringHashMap(u32) = undefined,
    used: std.ArrayList([]const u8) = .empty,
    /// label → number of references to that footnote rendered so far,
    /// incremented as each reference renders (issue #44): the second
    /// reference to a footnote gets id `fnref-N-2`, the third `fnref-N-3`,
    /// and the footnote body emits one backref per reference.
    ref_counts: std.StringHashMap(u32) = undefined,

    fn init(gpa: std.mem.Allocator, doc: *const document.Document) !Footnotes {
        var self = Footnotes{
            .numbers = std.StringHashMap(u32).init(gpa),
            .used = .empty,
            .ref_counts = std.StringHashMap(u32).init(gpa),
        };
        var it = try document.Document.Iterator.init(gpa, doc.root);
        defer it.deinit();
        while (try it.next()) |n| {
            if (n.tag != .footnote_ref or n.data.footnote_ref.label.len == 0) continue;
            const label = n.data.footnote_ref.label;
            if (self.numbers.contains(label)) continue;
            try self.numbers.put(label, @intCast(self.used.items.len + 1));
            try self.used.append(gpa, label);
        }
        return self;
    }

    fn deinit(self: *Footnotes, gpa: std.mem.Allocator) void {
        self.numbers.deinit();
        self.used.deinit(gpa);
        self.ref_counts.deinit();
    }

    fn number(self: *const Footnotes, label: []const u8) ?u32 {
        return self.numbers.get(label);
    }
};

/// A document contains verbatim source bytes (Markdown raw HTML leaves or
/// Textile `pre.` code blocks) that the XHTML profile cannot guarantee are
/// XML-well-formed. XHTML rendering fails closed with this error instead of
/// emitting possibly-malformed XML or silently rewriting content.
/// docs/XHTML.md §"Raw HTML policy".
pub const RawHtmlNotXmlWellFormed = error.RawHtmlNotXmlWellFormed;

/// Renders `doc` to `writer`.
///
/// `writer` may be any value with a `writeAll([]const u8) !void` method;
/// pass a pointer to it. In Zig 0.16, `std.Io.Writer` values (e.g. from
/// `std.Io.Writer.Allocating` or `std.Io.File.writer`) satisfy this.
///
/// `gpa` is used only for the temporary traversal stack, footnote numbering
/// tables, and heading-slug scratch; nothing is retained.
pub fn render(gpa: std.mem.Allocator, writer: anytype, doc: *const document.Document, options: RenderOptions) !void {
    var stack = std.ArrayList(Frame).empty;
    defer stack.deinit(gpa);

    // The footnote-numbering table is always allocated: `deinit` runs on
    // every path, so an `undefined` map here would be freed while uninitialized
    // (the managed HashMap's pointer-stability mutex is garbage) — a crash
    // that only manifests on some platforms/stack states.
    var fn_ctx = if (options.footnotes and doc.footnotes.items.len > 0)
        try Footnotes.init(gpa, doc)
    else
        Footnotes{ .numbers = std.StringHashMap(u32).init(gpa), .ref_counts = std.StringHashMap(u32).init(gpa) };
    defer fn_ctx.deinit(gpa);

    try stack.append(gpa, .{ .enter = .{
        .node = doc.root,
        .tight_item = false,
        .suppress_p = false,
        .prefix_newline = false,
        .footnote_backref = 0,
    } });
    while (stack.pop()) |frame| {
        switch (frame) {
            .enter => |f| {
                if (f.prefix_newline) try writer.writeByte('\n');
                try writeOpen(gpa, writer, &stack, f.node, f.suppress_p, f.footnote_backref, options, doc.src.bytes, &fn_ctx);
                try pushChildren(gpa, &stack, f.node, f.tight_item);
            },
            .marker => |text| try writer.writeAll(text),
            .backref => |n| try writeBackrefs(writer, &fn_ctx, n, options),
            .li_open => |n| {
                var buf: [32]u8 = undefined;
                const tag = try std.fmt.bufPrint(&buf, "<li id=\"fn-{d}\">\n", .{n});
                try writer.writeAll(tag);
            },
            .exit => |f| {
                // The document's exit pops last: everything else is already
                // rendered, so the footnotes section is pushed now and
                // renders in document order after the body.
                if (f.node.tag == .document and fn_ctx.used.items.len > 0) {
                    try pushFootnotesSection(gpa, &stack, doc, &fn_ctx, options);
                }
                try writeClose(writer, f.node, f.suppress_p, options, f.footnote_backref, &fn_ctx);
            },
        }
    }
}

const Frame = union(enum) {
    enter: struct {
        node: *const document.Node,
        /// True when `node` is a `.list_item` of a tight list; passed to
        /// `pushChildren` so the item's direct paragraph children know to
        /// render without `<p>` (§5.3).
        tight_item: bool,
        /// True when `node` is a `.paragraph` whose direct parent is a
        /// tight list's item: render without `<p>`.
        suppress_p: bool,
        /// Some block children of a list item need a line break before their
        /// opening tag. Tight paragraphs do not emit a trailing newline, so
        /// a following nested block supplies that separator here; the first
        /// block in a loose item also starts on the line after `<li>`.
        prefix_newline: bool,
        /// Footnote number whose back-reference anchor is appended inside
        /// this paragraph's close (a footnote definition's last paragraph,
        /// or 0 for none).
        footnote_backref: u32,
    },
    /// Literal output emitted when popped, used for the `<thead>`/`<tbody>`
    /// transitions between a table's header row and its body rows and for
    /// the footnotes section scaffolding.
    marker: []const u8,
    /// A footnote back-reference anchor, emitted when popped (the anchor is
    /// not a static string).
    backref: u32,
    /// A footnote `<li id="fn-N">` opener, emitted when popped (the number
    /// is not a static string).
    li_open: u32,
    /// `suppress_p` mirrors the decision made at open time, so the close
    /// tag matches; `footnote_backref` carries the paragraph-attached
    /// footnote back-reference to the close.
    exit: struct { node: *const document.Node, suppress_p: bool, footnote_backref: u32 },
};

fn pushChildren(
    gpa: std.mem.Allocator,
    stack: *std.ArrayList(Frame),
    node: *const document.Node,
    node_tight_item: bool,
) !void {
    // A GFM table's children are rows; the first is the header row, the rest
    // body rows. The `<thead>`/`<tbody>` split is emitted between them as
    // marker frames (GFM §4.10 output; no `<tbody>` with no body rows).
    // Textile tables (`.sections == false`) render as flat `<tr>` rows — the
    // references show no thead/tbody even with header cells
    // (docs/TEXTILE-PARITY.md §7). The table's own exit frame was already
    // pushed by `writeOpen`.
    if (node.tag == .table) {
        const n = node.children.items.len;
        if (!node.data.table.sections) {
            var i = n;
            while (i > 0) {
                i -= 1;
                try stack.append(gpa, .{ .enter = .{
                    .node = node.children.items[i],
                    .tight_item = false,
                    .suppress_p = false,
                    .prefix_newline = false,
                    .footnote_backref = 0,
                } });
            }
            return;
        }
        const has_body = n >= 2;
        var i = n;
        while (i > 1) {
            i -= 1;
            try stack.append(gpa, .{ .enter = .{
                .node = node.children.items[i],
                .tight_item = false,
                .suppress_p = false,
                .prefix_newline = false,
                .footnote_backref = 0,
            } });
        }
        try stack.append(gpa, .{ .marker = if (has_body) "</thead>\n<tbody>\n" else "</thead>\n" });
        try stack.append(gpa, .{ .enter = .{
            .node = node.children.items[0],
            .tight_item = false,
            .suppress_p = false,
            .prefix_newline = false,
            .footnote_backref = 0,
        } });
        try stack.append(gpa, .{ .marker = "<thead>\n" });
        return;
    }
    // A callout (extension): the title's inline nodes render first
    // (wrapped by the `<div class="callout-title">` opened in `writeOpen`
    // and closed by the marker), then the body blocks — the quote's
    // `children` are pure blocks (docs/CALLOUTS.md §4–§5).
    if (node.tag == .block_quote and node.data.block_quote.callout_type != null) {
        const bq = node.data.block_quote;
        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(gpa, .{ .enter = .{
                .node = node.children.items[i],
                .tight_item = false,
                .suppress_p = false,
                .prefix_newline = false,
                .footnote_backref = 0,
            } });
        }
        if (bq.callout_title_nodes.len > 0) {
            try stack.append(gpa, .{ .marker = "</div>\n" });
            var ti = bq.callout_title_nodes.len;
            while (ti > 0) {
                ti -= 1;
                try stack.append(gpa, .{ .enter = .{
                    .node = bq.callout_title_nodes[ti],
                    .tight_item = false,
                    .suppress_p = false,
                    .prefix_newline = false,
                    .footnote_backref = 0,
                } });
            }
        }
        return;
    }
    // A definition body renders its direct paragraphs like a tight list
    // item: a single-paragraph body is `<dd>text</dd>` (no `<p>`), while a
    // multi-block body keeps `<p>` wrappers (docs/MARKDOWN-EXTENSIONS.md).
    if (node.tag == .definition_body) {
        const tight = node.children.items.len == 1 and node.children.items[0].tag == .paragraph;
        var di = node.children.items.len;
        while (di > 0) {
            di -= 1;
            const c = node.children.items[di];
            const suppress = tight and c.tag == .paragraph;
            var prefix_newline = false;
            if (c.tag == .paragraph) {
                prefix_newline = !tight and di == 0;
            } else {
                prefix_newline = di == 0 or
                    (tight and di > 0 and node.children.items[di - 1].tag == .paragraph);
            }
            try stack.append(gpa, .{ .enter = .{
                .node = c,
                .tight_item = false,
                .suppress_p = suppress,
                .prefix_newline = prefix_newline,
                .footnote_backref = 0,
            } });
        }
        return;
    }
    var i = node.children.items.len;
    while (i > 0) {
        i -= 1;
        const c = node.children.items[i];
        // An item's direct paragraph children are suppressed iff its list
        // is tight; a list's children (items) carry the tight flag for
        // their own children.
        const tight = c.tag == .list_item and node.tag == .list and !node.data.list.loose;
        const suppress = c.tag == .paragraph and node.tag == .list_item and node_tight_item;
        var prefix_newline = false;
        if (node.tag == .list_item) {
            if (c.tag == .paragraph) {
                // A loose item's first paragraph starts after the opening
                // tag; tight paragraphs are inline with it. Later paragraphs
                // already follow a block's newline (or make the list loose).
                prefix_newline = !node_tight_item and i == 0;
            } else {
                // Nested containers and other block children always start
                // on a new line when first. A nested block following a tight
                // paragraph needs the separator that the suppressed
                // paragraph deliberately does not emit.
                prefix_newline = i == 0 or
                    (node_tight_item and i > 0 and node.children.items[i - 1].tag == .paragraph);
            }
        }
        try stack.append(gpa, .{ .enter = .{
            .node = c,
            .tight_item = tight,
            .suppress_p = suppress,
            .prefix_newline = prefix_newline,
            .footnote_backref = 0,
        } });
    }
}

fn writeOpen(
    gpa: std.mem.Allocator,
    writer: anytype,
    stack: *std.ArrayList(Frame),
    node: *const document.Node,
    suppress_p: bool,
    footnote_backref: u32,
    options: RenderOptions,
    src: []const u8,
    fn_ctx: *Footnotes,
) !void {
    switch (node.tag) {
        .document => {
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .block_quote => {
            const bq = node.data.block_quote;
            if (bq.callout_type) |ctype| {
                // Callout (extension, docs/CALLOUTS.md §5): a deliberate
                // element change from `<blockquote>` to the
                // Obsidian/admonition `<div class="callout callout-<type>">`
                // convention; `<div>` is a valid XHTML container. The
                // title, when present, opens inline here; its close is
                // emitted by a marker frame between the title nodes and
                // the body children (`pushChildren`).
                try writer.writeAll("<div class=\"callout callout-");
                try writeEscaped(writer, ctype);
                try writer.writeAll("\">\n");
                if (bq.callout_title_nodes.len > 0) {
                    try writer.writeAll("<div class=\"callout-title\">");
                }
            } else {
                try writer.writeAll("<blockquote");
                if (bq.cite) |cite| {
                    // `bq.:URL` citation: the cite attribute follows the
                    // link href policy (percent-encode + HTML-escape).
                    try writer.writeAll(" cite=\"");
                    try writeEscapedHref(writer, cite);
                    try writer.writeByte('\"');
                }
                try writeAttrs(writer, bq.attrs);
                try writer.writeAll(">\n");
            }
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .table => {
            try writer.writeAll("<table");
            try writeAttrs(writer, node.data.table.attrs);
            try writer.writeAll(">\n");
            // Children (rows with thead/tbody markers) are pushed by
            // `pushChildren`; only the exit frame is set here.
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .table_row => {
            try writer.writeAll("<tr");
            try writeAttrs(writer, node.data.table_row.attrs);
            try writer.writeByte('>');
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .table_cell => {
            const cell = node.data.table_cell;
            try writer.writeAll("\n<");
            try writer.writeAll(if (cell.header) "th" else "td");
            // Textile cell attributes (style/class/id/lang in the fixed
            // render order), then colspan/rowspan, then the GFM `align`.
            try writeAttrs(writer, cell.attrs);
            if (cell.colspan != 1) {
                var buf: [16]u8 = undefined;
                const attr = try std.fmt.bufPrint(&buf, " colspan=\"{d}\"", .{cell.colspan});
                try writer.writeAll(attr);
            }
            if (cell.rowspan != 1) {
                var buf: [16]u8 = undefined;
                const attr = try std.fmt.bufPrint(&buf, " rowspan=\"{d}\"", .{cell.rowspan});
                try writer.writeAll(attr);
            }
            switch (cell.alignment) {
                .none, .justify => {},
                .left => try writer.writeAll(" align=\"left\""),
                .center => try writer.writeAll(" align=\"center\""),
                .right => try writer.writeAll(" align=\"right\""),
            }
            try writer.writeByte('>');
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .list => {
            const list = node.data.list;
            switch (list.kind) {
                .bullet => try writer.writeAll("<ul>\n"),
                .ordered => {
                    if (list.start == 1) {
                        try writer.writeAll("<ol>\n");
                    } else {
                        var buf: [32]u8 = undefined;
                        const tag = try std.fmt.bufPrint(&buf, "<ol start=\"{d}\">\n", .{list.start});
                        try writer.writeAll(tag);
                    }
                },
                .definition => {
                    // Textile `dl.` definition list (Textile 2
                    // "Definition lists"); its items render `<dt>`/`<dd>`.
                    // A `dl<mods>.` signature's attrs land on the `<dl>`.
                    try writer.writeAll("<dl");
                    try writeAttrs(writer, list.attrs);
                    try writer.writeAll(">\n");
                },
            }
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .list_item => {
            // Textile definition-list items carry their role (term →
            // `<dt>`, definition → `<dd>`); plain list items are `<li>`.
            switch (node.data) {
                .list_item => |li| try writer.writeAll(if (li.role == .definition) "<dd>" else "<dt>"),
                else => try writer.writeAll("<li>"),
            }
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .paragraph => {
            // §5.3: a paragraph directly in a tight list's item renders
            // without `<p>` (`suppress_p` is computed at push time).
            if (!suppress_p) {
                try writer.writeAll("<p");
                try writeAttrs(writer, node.data.paragraph.attrs);
                try writer.writeByte('>');
            }
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = suppress_p, .footnote_backref = footnote_backref } });
        },
        .heading => {
            const level = clampHeading(node.data.heading.level);
            var buf: [8]u8 = undefined;
            const tag = try std.fmt.bufPrint(&buf, "<h{d}", .{level});
            try writer.writeAll(tag);
            const h = node.data.heading;
            if (h.id) |id| {
                try writer.writeAll(" id=\"");
                try writeEscaped(writer, id);
                try writer.writeByte('"');
            } else if (options.heading_ids) {
                // GFM auto-id: a slug of the heading's plain-text content
                // (its inline children).
                var text_buf = std.ArrayList(u8).empty;
                defer text_buf.deinit(gpa);
                for (node.children.items) |c| try collectHeadingText(gpa, c, &text_buf);
                const slug = try slugify(gpa, text_buf.items);
                defer gpa.free(slug);
                if (slug.len > 0) {
                    try writer.writeAll(" id=\"");
                    try writeEscaped(writer, slug);
                    try writer.writeByte('"');
                }
            }
            if (h.class) |cls| {
                try writer.writeAll(" class=\"");
                try writeEscaped(writer, cls);
                try writer.writeByte('"');
            }
            try writeAttrs(writer, h.attrs);
            try writer.writeByte('>');
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .definition_list => {
            try writer.writeAll("<dl>\n");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .definition_term => {
            try writer.writeAll("<dt>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .definition_body => {
            try writer.writeAll("<dd>");
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .footnote => {
            // A footnote definition node is only rendered inside the
            // footnotes section; a hand-built document that places one
            // elsewhere renders nothing.
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .thematic_break => {
            try writer.writeAll(if (voidSlash(options)) "<hr />\n" else "<hr>\n");
        },
        .code_block => {
            const code = node.data.code_block;
            // Textile `pre.` renders the content verbatim inside `<pre>`
            // (no `<code>` wrapper, no escaping, no info class;
            // docs/TEXTILE-PARITY.md §8). Verbatim content cannot be
            // guaranteed XML-well-formed, so the XHTML profile rejects it.
            if (options.profile == .xhtml and !code.escape) return RawHtmlNotXmlWellFormed;
            try writer.writeAll("<pre");
            try writeAttrs(writer, code.attrs);
            if (!code.escape) {
                try writer.writeByte('>');
                try writer.writeAll(code.content);
                try writer.writeAll("</pre>\n");
            } else {
                try writer.writeAll("><code");
                if (code.info) |info| {
                    const language_end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
                    if (language_end > 0) {
                        try writer.writeAll(" class=\"language-");
                        try writeEscaped(writer, info[0..language_end]);
                        try writer.writeByte('"');
                    }
                }
                try writer.writeByte('>');
                try writeEscaped(writer, code.content);
                try writer.writeAll("</code></pre>\n");
            }
        },
        .html_block => {
            // Leaf block: the verbatim container-stripped source lines, no
            // escaping (the raw-HTML policy of docs/RAW-HTML.md §3). The
            // XHTML profile is fail-closed: verbatim source cannot be
            // guaranteed XML-well-formed. Every block is followed by exactly
            // one `\n`, so an unterminated final line gets one here (the
            // reference implementation's `cr()`).
            if (options.profile == .xhtml) return RawHtmlNotXmlWellFormed;
            const content = node.data.html_block;
            try writer.writeAll(content);
            if (content.len == 0 or content[content.len - 1] != '\n') try writer.writeByte('\n');
        },
        .emphasis, .strong, .bold, .italic, .deleted, .inserted, .big, .small, .superscript, .subscript, .cite => {
            // Textile phrase tags. The attribute-bearing forms
            // (`*{style}x*`, `_(class)x_`, Hobix "Phrase Attributes") write
            // the composed attrs on the phrase's own tag; nodes without a
            // `.phrase` payload (plain Textile phrases, all Markdown
            // phrases) render with no attrs.
            try writer.writeAll("<");
            try writer.writeAll(phraseTagName(node.tag));
            try writeAttrs(writer, phraseAttrs(node));
            try writer.writeByte('>');
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .footnote_ref => {
            const fr = node.data.footnote_ref;
            if (fr.label.len == 0) {
                // Textile `[N]` reference (Textile 2 "Footnotes"):
                // `<sup class="footnote"><a href="#fnN">N</a></sup>`.
                var buf: [16]u8 = undefined;
                const num = try std.fmt.bufPrint(&buf, "{d}", .{fr.number});
                try writer.writeAll("<sup class=\"footnote\"><a href=\"#fn");
                try writer.writeAll(num);
                try writer.writeAll("\">");
                try writer.writeAll(num);
                try writer.writeAll("</a></sup>");
            } else if (fn_ctx.number(fr.label)) |n| {
                // Markdown `[^label]` (extension), numbered in
                // first-reference order. Repeated references to the same
                // footnote get distinct ids: the first is `fnref-N`, the
                // second `fnref-N-2`, the third `fnref-N-3`, and so on
                // (issue #44) so each reference is individually
                // addressable and duplicate ids are impossible.
                const ord = (fn_ctx.ref_counts.get(fr.label) orelse 0) + 1;
                try fn_ctx.ref_counts.put(fr.label, ord);
                var num_buf: [16]u8 = undefined;
                const num = try std.fmt.bufPrint(&num_buf, "{d}", .{n});
                try writer.writeAll("<sup class=\"footnote-ref\"><a href=\"#fn-");
                try writer.writeAll(num);
                try writer.writeAll("\" id=\"fnref-");
                if (ord == 1) {
                    try writer.writeAll(num);
                } else {
                    var id_buf: [48]u8 = undefined;
                    const id = try std.fmt.bufPrint(&id_buf, "{d}-{d}", .{ n, ord });
                    try writer.writeAll(id);
                }
                try writer.writeByte('"');
                try writeValuelessAttr(writer, options, "data-footnote-ref");
                try writer.writeByte('>');
                try writer.writeAll(num);
                try writer.writeAll("</a></sup>");
            } else {
                // A hand-built document with an undefined label: literal.
                try writeEscaped(writer, fr.label);
            }
        },
        .span => {
            // Textile `%x%` renders `<span>`; the phrase-attribute forms
            // (`%{style}(class#id)[lang]x%`, Hobix "Phrase Attributes")
            // write the composed attrs in the fixed render order
            // (docs/TEXTILE-PARITY.md §18). Markdown never produces this tag.
            try writer.writeAll("<span");
            try writeAttrs(writer, node.data.span.attrs);
            try writer.writeByte('>');
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .code_span => {
            try writer.writeAll("<code>");
            // Leaf tag: the (normalized) content is escaped like text
            // (& < > " and NUL -> U+FFFD), written on enter.
            try writeEscaped(writer, node.data.code_span);
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .link => {
            try writer.writeAll("<a href=\"");
            try writeEscapedHref(writer, node.data.link.href);
            try writer.writeByte('\"');
            if (node.data.link.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscaped(writer, title);
                try writer.writeByte('\"');
            }
            try writer.writeByte('>');
            try stack.append(gpa, .{ .exit = .{ .node = node, .suppress_p = false, .footnote_backref = 0 } });
        },
        .autolink => {
            // Leaf tag: one <a> with the raw label as its text. The href
            // follows the link href policy (percent-encode + HTML-escape);
            // the label is the raw content HTML-escaped like text
            // (docs/AUTOLINKS.md §3). No title, fixed attribute order.
            try writer.writeAll("<a href=\"");
            try writeEscapedHref(writer, node.data.autolink.href);
            try writer.writeAll("\">");
            try writeEscaped(writer, node.data.autolink.label);
            try writer.writeAll("</a>");
        },
        .wikilink => {
            // Leaf tag (extension): one <a> with the resolved text.
            // Resolution is a renderer policy (docs/WIKILINKS.md §5): the
            // default percent-encodes the target as the href with `label
            // orelse target` as the text; a consumer resolver overrides
            // both. The href follows the link href policy; the text is
            // HTML-escaped like text. No title, fixed attribute order.
            const w = node.data.wikilink;
            const resolved: ResolvedWikilink = if (options.wikilink_resolver) |res|
                res(w.target, w.label, options.wikilink_resolver_ctx)
            else
                .{ .href = w.target, .text = w.label orelse w.target };
            try writer.writeAll("<a href=\"");
            try writeEscapedHref(writer, resolved.href);
            try writer.writeAll("\">");
            try writeEscaped(writer, resolved.text);
            try writer.writeAll("</a>");
        },
        .image => {
            // Void element: the whole tag is written on enter and no exit
            // frame is pushed (leaf tag, no children). `src` follows the
            // href policy; `alt` is always emitted (possibly empty) and
            // HTML-escaped like text; `title`, the Textile `width`/`height`
            // (dimensions or percentages), and the Textile attribute list
            // (style/class/id) only when present, in that fixed order.
            try writer.writeAll("<img src=\"");
            try writeEscapedHref(writer, node.data.image.src);
            try writer.writeAll("\" alt=\"");
            try writeEscaped(writer, node.data.image.alt);
            try writer.writeByte('\"');
            if (node.data.image.title) |title| {
                try writer.writeAll(" title=\"");
                try writeEscaped(writer, title);
                try writer.writeByte('\"');
            }
            if (node.data.image.width) |width| {
                try writer.writeAll(" width=\"");
                try writeEscaped(writer, width);
                try writer.writeByte('\"');
            }
            if (node.data.image.height) |height| {
                try writer.writeAll(" height=\"");
                try writeEscaped(writer, height);
                try writer.writeByte('\"');
            }
            try writeAttrs(writer, node.data.image.attrs);
            try writer.writeAll(if (voidSlash(options)) " />" else ">");
        },
        .acronym => {
            // Textile `CSS(Cascading Style Sheets)` → `<acronym
            // title="…">CSS</acronym>` (Hobix "Acronyms"): the definition
            // is the title and the uppercase letters are the display text,
            // both escaped like text. Markdown never produces this tag.
            try writer.writeAll("<acronym title=\"");
            try writeEscaped(writer, node.data.acronym.title);
            try writer.writeAll("\">");
            try writeEscaped(writer, node.data.acronym.text);
            try writer.writeAll("</acronym>");
        },
        .text => try writeEscapedText(writer, node.data.text),
        .raw_html => {
            // Leaf tag: the raw source bytes of the construct, verbatim —
            // no escaping (docs/RAW-HTML.md §3). The span may include line
            // endings inside a multi-line tag. The XHTML profile is
            // fail-closed: verbatim source cannot be guaranteed
            // XML-well-formed.
            if (options.profile == .xhtml) return RawHtmlNotXmlWellFormed;
            try writer.writeAll(src[node.span.start..node.span.end]);
        },
        .soft_break => try writer.writeAll("\n"),
        .hard_break => {
            try writer.writeAll(if (voidSlash(options)) "<br />" else "<br>");
            try writer.writeAll("\n");
        },
    }
}

fn writeClose(writer: anytype, node: *const document.Node, suppress_p: bool, options: RenderOptions, footnote_backref: u32, fn_ctx: *const Footnotes) !void {
    switch (node.tag) {
        .document, .footnote => {},
        .block_quote => {
            // Callout close: the wrapper div (the title div was closed by
            // its marker frame; docs/CALLOUTS.md §5).
            if (node.data.block_quote.callout_type != null) {
                try writer.writeAll("</div>\n");
            } else {
                try writer.writeAll("</blockquote>\n");
            }
        },
        .table => {
            // The thead/tbody split is emitted by marker frames between the
            // rows; only the tail (tbody close, table close) is written here
            // (Textile tables are flat and skip the tbody close).
            if (node.data.table.sections and node.children.items.len >= 2) try writer.writeAll("</tbody>\n");
            try writer.writeAll("</table>\n");
        },
        .table_row => try writer.writeAll("\n</tr>\n"),
        .table_cell => {
            try writer.writeAll(if (node.data.table_cell.header) "</th>" else "</td>");
        },
        .list => {
            switch (node.data.list.kind) {
                .bullet => try writer.writeAll("</ul>\n"),
                .ordered => try writer.writeAll("</ol>\n"),
                .definition => try writer.writeAll("</dl>\n"),
            }
        },
        .list_item => {
            switch (node.data) {
                .list_item => |li| try writer.writeAll(if (li.role == .definition) "</dd>\n" else "</dt>\n"),
                else => try writer.writeAll("</li>\n"),
            }
        },
        .definition_list => try writer.writeAll("</dl>\n"),
        .definition_term => try writer.writeAll("</dt>\n"),
        .definition_body => try writer.writeAll("</dd>\n"),
        .paragraph => {
            if (suppress_p) {
                // Tight-list paragraphs are inline content of `<li>`; a
                // following block gets its own leading newline in its frame.
            } else {
                if (footnote_backref > 0) try writeBackrefs(writer, fn_ctx, footnote_backref, options);
                try writer.writeAll("</p>\n");
            }
        },
        .heading => {
            const level = clampHeading(node.data.heading.level);
            var buf: [8]u8 = undefined;
            const tag = try std.fmt.bufPrint(&buf, "</h{d}>\n", .{level});
            try writer.writeAll(tag);
        },
        .emphasis => try writer.writeAll("</em>"),
        .strong => try writer.writeAll("</strong>"),
        .bold => try writer.writeAll("</b>"),
        .italic => try writer.writeAll("</i>"),
        .deleted => try writer.writeAll("</del>"),
        .inserted => try writer.writeAll("</ins>"),
        .big => try writer.writeAll("</big>"),
        .small => try writer.writeAll("</small>"),
        .superscript => try writer.writeAll("</sup>"),
        .subscript => try writer.writeAll("</sub>"),
        .cite => try writer.writeAll("</cite>"),
        .span => try writer.writeAll("</span>"),
        .code_span => try writer.writeAll("</code>"),
        .link => try writer.writeAll("</a>"),
        // These tags never push exit frames.
        .thematic_break, .code_block, .html_block, .text, .image, .autolink, .wikilink, .raw_html, .soft_break, .hard_break, .footnote_ref, .acronym => unreachable,
    }
}

/// Writes the footnote back-reference anchors for footnote `n` (each with
/// a leading space so they read as `note body <a ...>↩</a>` inside a
/// paragraph). One anchor per reference to the footnote, in reference
/// order: the first points at `#fnref-N`, the second at `#fnref-N-2`, and
/// so on (issue #44) — so a reader who followed any reference can get
/// back to it, and each anchor has its own target.
fn writeBackrefs(writer: anytype, fn_ctx: *const Footnotes, n: u32, options: RenderOptions) !void {
    const label = fn_ctx.used.items[n - 1]; // numbers are 1-based, used is 0-based
    const count = fn_ctx.ref_counts.get(label) orelse 1;
    // The valueless `data-footnote-backref` marker is bare in HTML and an
    // explicit empty value under XHTML (issue #60).
    const empty_value = if (options.profile == .xhtml) "=\"\"" else "";
    var ord: u32 = 1;
    while (ord <= count) : (ord += 1) {
        var buf: [256]u8 = undefined;
        const text = if (ord == 1)
            try std.fmt.bufPrint(
                &buf,
                " <a href=\"#fnref-{d}\" class=\"footnote-backref\" data-footnote-backref{s} data-footnote-backref-idx=\"{d}\" aria-label=\"Back to reference {d}\">↩</a>",
                .{ n, empty_value, n, n },
            )
        else
            try std.fmt.bufPrint(
                &buf,
                " <a href=\"#fnref-{d}-{d}\" class=\"footnote-backref\" data-footnote-backref{s} data-footnote-backref-idx=\"{d}-{d}\" aria-label=\"Back to reference {d}-{d}\">↩</a>",
                .{ n, ord, empty_value, n, ord, n, ord },
            );
        try writer.writeAll(text);
    }
}

/// Finds the registered footnote definition for a label (linear scan;
/// definitions are few).
fn findFootnoteDef(doc: *const document.Document, label: []const u8) ?document.FootnoteDef {
    for (doc.footnotes.items) |fd| {
        if (std.mem.eql(u8, fd.label, label)) return fd;
    }
    return null;
}

/// Pushes the frames for the footnotes `<section>` onto the stack. Called
/// when the document's exit frame pops, so the whole body is already
/// rendered; the pushed frames then render in document order after it.
/// Frames are pushed in reverse pop order: the closing markers first, each
/// `<li>`'s close before its blocks, and the section/ol markers last.
fn pushFootnotesSection(
    gpa: std.mem.Allocator,
    stack: *std.ArrayList(Frame),
    doc: *const document.Document,
    fn_ctx: *const Footnotes,
    options: RenderOptions,
) !void {
    try stack.append(gpa, .{ .marker = "</section>\n" });
    try stack.append(gpa, .{ .marker = "</ol>\n" });
    // Frames pop LIFO, so the last-used footnote is pushed first.
    var u = fn_ctx.used.items.len;
    while (u > 0) {
        u -= 1;
        const label = fn_ctx.used.items[u];
        const n = fn_ctx.number(label) orelse continue;
        const def = findFootnoteDef(doc, label) orelse continue;
        const children = def.node.children.items;
        try stack.append(gpa, .{ .marker = "</li>\n" });
        var i = children.len;
        while (i > 0) {
            i -= 1;
            const c = children[i];
            const backref: u32 = if (i == children.len - 1 and c.tag == .paragraph) n else 0;
            try stack.append(gpa, .{ .enter = .{
                .node = c,
                .tight_item = false,
                .suppress_p = false,
                .prefix_newline = false,
                .footnote_backref = backref,
            } });
        }
        if (children.len == 0 or children[children.len - 1].tag != .paragraph) {
            // No trailing paragraph to carry the back-reference: emit the
            // anchor on its own before the `</li>`.
            try stack.append(gpa, .{ .backref = n });
        }
        try stack.append(gpa, .{ .li_open = n });
    }
    try stack.append(gpa, .{ .marker = "<ol>\n" });
    const section_marker = if (options.profile == .xhtml)
        "<section class=\"footnotes\" data-footnotes=\"\">\n"
    else
        "<section class=\"footnotes\" data-footnotes>\n";
    try stack.append(gpa, .{ .marker = section_marker });
}

/// Collects the plain-text projection of a heading's inline content: text
/// (entity-decoded, escapes already split into their own text nodes),
/// code-span content, image alt, autolink labels, and the text of nested
/// inline containers. Soft/hard breaks become spaces; raw HTML is skipped.
fn collectHeadingText(gpa: std.mem.Allocator, node: *const document.Node, out: *std.ArrayList(u8)) !void {
    switch (node.tag) {
        .text => try writeDecodedText(gpa, out, node.data.text),
        .code_span => try out.appendSlice(gpa, node.data.code_span),
        .image => try out.appendSlice(gpa, node.data.image.alt),
        .autolink => try out.appendSlice(gpa, node.data.autolink.label),
        .wikilink => try out.appendSlice(gpa, node.data.wikilink.label orelse node.data.wikilink.target),
        .soft_break, .hard_break => try out.append(gpa, ' '),
        .raw_html => {},
        .link, .emphasis, .strong, .bold, .italic, .deleted, .inserted, .superscript, .subscript, .span => {
            for (node.children.items) |c| try collectHeadingText(gpa, c, out);
        },
        else => {},
    }
}

/// Appends the entity-decoded bytes of `text` (no HTML escaping) — the
/// plain-text projection used for heading slugs. A backslash-escaped `&`
/// is its own text node (the escape split), so it has no trailing `;` and
/// stays literal here.
fn writeDecodedText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (entities.decodeAt(text, i)) |dec| {
                try out.appendSlice(gpa, text[start..i]);
                try out.appendSlice(gpa, dec.bytes[0..dec.len]);
                i = dec.next;
                start = i;
                continue;
            }
        }
        i += 1;
    }
    try out.appendSlice(gpa, text[start..]);
}

/// GFM-style heading slug (docs/MARKDOWN-EXTENSIONS.md): lowercase ASCII
/// letters; keep `a-z 0-9 _ -`; collapse every whitespace run into one `-`;
/// drop everything else (including non-ASCII bytes); trim leading/trailing
/// `-`. This is the §5.3 algorithm applied byte-wise, which reproduces the
/// observed GitHub behavior for `Café résumé` → `caf-rsum` (accented bytes
/// are not ASCII letters and are dropped).
fn slugify(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    var pending_space = false;
    for (text) |b| {
        const c: u8 = switch (b) {
            'A'...'Z' => b + 32,
            'a'...'z', '0'...'9', '_', '-' => b,
            ' ', '\t', '\n', '\r' => {
                pending_space = true;
                continue;
            },
            else => continue,
        };
        if (pending_space) {
            if (buf.items.len > 0) try buf.append(gpa, '-');
            pending_space = false;
        }
        try buf.append(gpa, c);
    }
    var end = buf.items.len;
    while (end > 0 and buf.items[end - 1] == '-') end -= 1;
    buf.shrinkRetainingCapacity(end);
    return buf.toOwnedSlice(gpa);
}

/// Heading levels are clamped to 1..6 so hand-built documents with invalid
/// levels still render deterministically. Dialect frontends only produce
/// valid levels, so clamping is purely defensive.
fn clampHeading(level: u8) u8 {
    return @min(@max(level, 1), 6);
}

/// Whether void elements serialize with the XML empty-element trailing
/// slash. The XHTML profile always uses it; HTML mode follows
/// `RenderOptions.void_trailing_slash` (default CommonMark reference style).
fn voidSlash(options: RenderOptions) bool {
    return options.profile == .xhtml or options.void_trailing_slash;
}

/// Writes a valueless boolean-style attribute (e.g. `data-footnote-ref`).
/// The HTML profile emits the bare form; the XHTML profile must stay
/// XML-well-formed (a valueless attribute is not valid XML), so it writes
/// an explicit empty value (`data-footnote-ref=""`). docs/XHTML.md.
fn writeValuelessAttr(writer: anytype, options: RenderOptions, name: []const u8) !void {
    try writer.writeByte(' ');
    try writer.writeAll(name);
    if (options.profile == .xhtml) try writer.writeAll("=\"\"");
}

/// The HTML tag name for the Textile phrase tags (the ones with a shared
/// `.phrase`-or-`.none` payload). `.span` is handled separately.
fn phraseTagName(tag: document.Tag) []const u8 {
    return switch (tag) {
        .emphasis => "em",
        .strong => "strong",
        .bold => "b",
        .italic => "i",
        .deleted => "del",
        .inserted => "ins",
        .big => "big",
        .small => "small",
        .superscript => "sup",
        .subscript => "sub",
        .cite => "cite",
        else => unreachable,
    };
}

/// The composed attrs of a phrase node, or none when the node carries no
/// `.phrase` payload (plain Textile phrases and all Markdown phrases keep
/// `.none`, so the renderer never requires the payload).
fn phraseAttrs(node: *const document.Node) []const document.Attribute {
    return switch (node.data) {
        .phrase => |p| p.attrs,
        else => &.{},
    };
}

/// Emits an ordered attribute list as ` name="value"` pairs (the fixed
/// render order for Textile attributes: style, class, id, lang). Values
/// are HTML-escaped like text content.
fn writeAttrs(writer: anytype, attrs: []const document.Attribute) !void {
    for (attrs) |a| {
        try writer.writeByte(' ');
        try writer.writeAll(a.name);
        try writer.writeAll("=\"");
        try writeEscaped(writer, a.value);
        try writer.writeByte('"');
    }
}

/// Percent-encodes the href per Oliver's documented URL policy (see the
/// module comment), then HTML-escapes the result (`&` -> `&amp;`; the other
/// specials were already percent-encoded). Non-ASCII bytes are each encoded
/// as `%XX` (uppercase hex), a renderer choice the spec explicitly leaves
/// open.
fn writeEscapedHref(writer: anytype, href: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < href.len) : (i += 1) {
        const b = href[i];
        // `&` is URL-safe (kept unencoded) but must be `&amp;` inside an
        // HTML attribute value; the other attribute specials (`< > "`)
        // were already percent-encoded.
        if (b == '&') {
            if (i > start) try writer.writeAll(href[start..i]);
            try writer.writeAll("&amp;");
            start = i + 1;
            continue;
        }
        if (hrefSafe(b)) continue;
        if (i > start) try writer.writeAll(href[start..i]);
        var buf: [3]u8 = undefined;
        const hex = "0123456789ABCDEF";
        buf[0] = '%';
        buf[1] = hex[b >> 4];
        buf[2] = hex[b & 0xF];
        try writer.writeAll(&buf);
        start = i + 1;
    }
    if (start < href.len) try writer.writeAll(href[start..]);
}

/// URL-safe characters, i.e. left unpercent-encoded: RFC 3986 unreserved
/// (`A-Za-z0-9-._~`) plus the sub-delims (`!$&'()*+,;=`) and the reserved
/// chars the spec examples keep unencoded (`:/?#@`) plus `%` (existing
/// escapes are left alone; "all URL-escaped characters are also valid URL
/// characters"). Everything else — space, `"`, `\`, `<`, `>`, backtick,
/// brackets, control chars, and all non-ASCII — is percent-encoded. `&` is
/// URL-safe but still HTML-escaped to `&amp;` in the attribute (see
/// `writeEscapedHref`).
fn hrefSafe(b: u8) bool {
    return switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '-', '_', '.', '~', '!', '*', '\'', '(', ')', ',', ';', ':', '&', '=', '+', '$', '#', '@', '/', '?', '%' => true,
        else => false,
    };
}

/// Escapes text content. `&`, `<`, `>`, and `"` are escaped (the set the
/// CommonMark reference output escapes); NUL is replaced with U+FFFD.
fn writeEscaped(writer: anytype, text: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const replacement: []const u8 = switch (text[i]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            0 => "\xEF\xBF\xBD", // U+FFFD
            else => continue,
        };
        if (i > start) try writer.writeAll(text[start..i]);
        try writer.writeAll(replacement);
        start = i + 1;
    }
    if (start < text.len) try writer.writeAll(text[start..]);
}

/// Escapes text content after decoding §2.5 entity and numeric character
/// references: the decoded character is escaped like any other text byte,
/// so `&amp;` renders as `&amp;`, `&#X22;` as `&quot;`, and `&ouml;` as
/// `ö`. Text nodes borrow the source (docs/DOCUMENT-MODEL.md invariant 9),
/// so entity decoding happens here at render time, exactly where the
/// delimiter scanner and inline matcher can no longer see it (an
/// entity-produced `*` is text, never an emphasis delimiter). Code spans
/// and code blocks keep `writeEscaped` — references are literal there.
fn writeEscapedText(writer: anytype, text: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (entities.decodeAt(text, i)) |dec| {
                if (i > start) try writeEscaped(writer, text[start..i]);
                try writeEscaped(writer, dec.bytes[0..dec.len]);
                i = dec.next;
                start = i;
                continue;
            }
        }
        i += 1;
    }
    if (start < text.len) try writeEscaped(writer, text[start..]);
}

// ---------------------------------------------------------------------------
// Tests: rendering directly from hand-constructed documents, independent of
// either dialect frontend.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderDoc(doc: *document.Document) !std.ArrayList(u8) {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try render(testing.allocator, &aw.writer, doc, .{});
    return aw.toArrayList();
}

fn addText(doc: *document.Document, parent: *document.Node, text: []const u8) !void {
    const node = try doc.createNode(.text, .{ .start = 0, .end = @intCast(text.len) }, .{ .text = text });
    try doc.appendChild(parent, node);
}

test "html: escaping" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    try addText(&doc, p, "a & b < c > d \" e \x00 f");
    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p>a &amp; b &lt; c &gt; d &quot; e \u{FFFD} f</p>\n", out.items);
}

test "html: soft vs hard breaks and void option" {
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try addText(&doc, p, "a");
        try doc.appendChild(p, try doc.createNode(.soft_break, .{ .start = 0, .end = 0 }, .none));
        try addText(&doc, p, "b");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>a\nb</p>\n", out.items);
    }
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try addText(&doc, p, "a");
        try doc.appendChild(p, try doc.createNode(.hard_break, .{ .start = 0, .end = 0 }, .none));
        try addText(&doc, p, "b");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>a<br />\nb</p>\n", out.items);

        // void_trailing_slash = false gives HTML5-style <br>.
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try render(testing.allocator, &aw.writer, &doc, .{ .void_trailing_slash = false });
        var out2 = aw.toArrayList();
        defer out2.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>a<br>\nb</p>\n", out2.items);
    }
}

test "html: heading clamp and empty document" {
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        try doc.appendChild(doc.root, try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{ .heading = .{ .level = 0 } }));
        try doc.appendChild(doc.root, try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{ .heading = .{ .level = 7 } }));
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<h1></h1>\n<h6></h6>\n", out.items);
    }
    {
        // Empty document renders to empty output.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("", out.items);
    }
}

test "html: emphasis and strong render from hand-built documents" {
    // Renderer-only: emphasis/strong nodes built by hand, not parsed — the
    // renderer consumes the model, not the dialect (docs/INLINE-PARSING.md
    // §15, "Renderer-only").
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    const em = try doc.createNode(.emphasis, .{ .start = 0, .end = 12 }, .none);
    try doc.appendChild(p, em);
    try addText(&doc, em, "a ");
    const strong = try doc.createNode(.strong, .{ .start = 3, .end = 9 }, .none);
    try doc.appendChild(em, strong);
    try addText(&doc, strong, "b");
    try addText(&doc, em, " c");
    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p><em>a <strong>b</strong> c</em></p>\n", out.items);
}

test "html: code span content is escaped, not re-parsed" {
    // Renderer-only: a hand-built code_span with markup-ish payload must
    // render the payload escaped inside <code> — the renderer never treats
    // code_span content as inline markup (leaf inline, docs/DOCUMENT-MODEL).
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    const cs = try doc.createNode(.code_span, .{ .start = 0, .end = 14 }, .{ .code_span = "a <b>& \"c\"`" });
    try doc.appendChild(p, cs);
    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p><code>a &lt;b&gt;&amp; &quot;c&quot;`</code></p>\n", out.items);
}

test "html: raw HTML leaves write source spans verbatim" {
    const input = "<b>&</b>";
    var doc = try document.Document.init(testing.allocator, .{ .bytes = input });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = @intCast(input.len) }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    try doc.appendChild(p, try doc.createNode(.raw_html, .{ .start = 0, .end = 3 }, .none));
    try doc.appendChild(p, try doc.createNode(.text, .{ .start = 3, .end = 4 }, .{ .text = doc.text(.{ .start = 3, .end = 4 }) }));
    try doc.appendChild(p, try doc.createNode(.raw_html, .{ .start = 4, .end = 8 }, .none));

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p><b>&amp;</b></p>\n", out.items);
}

test "html: link renders href and title with escaping policy" {
    // Renderer-only: hand-built link nodes — the renderer consumes the
    // model, never the dialect (docs/DOCUMENT-MODEL.md).
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
            .link = .{ .href = "/uri", .title = "the title" },
        });
        try doc.appendChild(p, lnk);
        try addText(&doc, lnk, "foo");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><a href=\"/uri\" title=\"the title\">foo</a></p>\n", out.items);
    }
    {
        // href percent-encoding: space, quote, backslash, and non-ASCII are
        // encoded; `&` is HTML-escaped; safe URL chars stay.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
            .link = .{ .href = "/my url\"\\foo()a&b", .title = null },
        });
        try doc.appendChild(p, lnk);
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><a href=\"/my%20url%22%5Cfoo()a&amp;b\"></a></p>\n", out.items);
    }
    {
        // title escaping: HTML-escaped, no percent-encoding.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
            .link = .{ .href = "/u", .title = "a \"b\" & <c>" },
        });
        try doc.appendChild(p, lnk);
        try addText(&doc, lnk, "x");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><a href=\"/u\" title=\"a &quot;b&quot; &amp; &lt;c&gt;\">x</a></p>\n", out.items);
    }
    {
        // No title attribute when the title is absent.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
            .link = .{ .href = "/u", .title = null },
        });
        try doc.appendChild(p, lnk);
        try addText(&doc, lnk, "x");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><a href=\"/u\">x</a></p>\n", out.items);
    }
}

test "html: image renders as a void element with fixed attribute order" {
    // Renderer-only: hand-built image nodes — the renderer consumes the
    // model, never the dialect (docs/IMAGES-PARSING.md §4).
    {
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
            .image = .{ .src = "/uri", .alt = "foo", .title = "the title" },
        }));
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><img src=\"/uri\" alt=\"foo\" title=\"the title\" /></p>\n", out.items);
    }
    {
        // Empty alt is always emitted; no title attribute when absent.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
            .image = .{ .src = "/u", .alt = "", .title = null },
        }));
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><img src=\"/u\" alt=\"\" /></p>\n", out.items);
    }
    {
        // src percent-encoding follows the href policy; alt and title are
        // HTML-escaped like text.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
            .image = .{ .src = "/my url\"&x", .alt = "a <b> & \"c\"", .title = "t&t" },
        }));
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings(
            "<p><img src=\"/my%20url%22&amp;x\" alt=\"a &lt;b&gt; &amp; &quot;c&quot;\" title=\"t&amp;t\" /></p>\n",
            out.items,
        );
    }
    {
        // void_trailing_slash = false gives the HTML5-style <img>.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
            .image = .{ .src = "/u", .alt = "a", .title = null },
        }));
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try render(testing.allocator, &aw.writer, &doc, .{ .void_trailing_slash = false });
        var out = aw.toArrayList();
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><img src=\"/u\" alt=\"a\"></p>\n", out.items);
    }
}

test "html: tight and loose lists keep block framing deterministic" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();

    const list = try doc.createNode(.list, .{ .start = 0, .end = 0 }, .{ .list = .{
        .kind = .bullet,
        .bullet = '-',
        .loose = false,
    } });
    try doc.appendChild(doc.root, list);

    const first = try doc.createNode(.list_item, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(list, first);
    const first_p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(first, first_p);
    try addText(&doc, first_p, "one");

    const nested = try doc.createNode(.list, .{ .start = 0, .end = 0 }, .{ .list = .{
        .kind = .ordered,
        .delimiter = '.',
        .start = 3,
    } });
    try doc.appendChild(first, nested);
    const nested_item = try doc.createNode(.list_item, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(nested, nested_item);
    const nested_p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(nested_item, nested_p);
    try addText(&doc, nested_p, "three");

    const second = try doc.createNode(.list_item, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(list, second);
    const second_p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(second, second_p);
    try addText(&doc, second_p, "two");

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<ul>\n<li>one\n<ol start=\"3\">\n<li>three</li>\n</ol>\n</li>\n<li>two</li>\n</ul>\n",
        out.items,
    );

    list.data.list.loose = true;
    var loose_out = try renderDoc(&doc);
    defer loose_out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<ul>\n<li>\n<p>one</p>\n<ol start=\"3\">\n<li>three</li>\n</ol>\n</li>\n<li>\n<p>two</p>\n</li>\n</ul>\n",
        loose_out.items,
    );
}

test "html: mixed blocks render independently of dialect" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    try doc.appendChild(doc.root, try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{ .heading = .{ .level = 2 } }));
    try doc.appendChild(doc.root, try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} }));
    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<h2></h2>\n<p></p>\n", out.items);
}

test "html: table renders thead/tbody sections and alignment attributes" {
    // Renderer-only: a hand-built table — the renderer consumes the model,
    // never the dialect (docs/DOCUMENT-MODEL.md). Row 0 is the header row;
    // each cell carries its own header/alignment flags.
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const table = try doc.createNode(.table, .{ .start = 0, .end = 0 }, .{
        .table = .{ .alignment = &.{ .none, .center, .right }, .sections = true },
    });
    try doc.appendChild(doc.root, table);

    // Header row: three cells (plain, center-aligned, right-aligned).
    const header = try doc.createNode(.table_row, .{ .start = 0, .end = 0 }, .{ .table_row = .{} });
    try doc.appendChild(table, header);
    const h1 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = true, .alignment = .none } });
    try doc.appendChild(header, h1);
    try addText(&doc, h1, "foo");
    const h2 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = true, .alignment = .center } });
    try doc.appendChild(header, h2);
    try addText(&doc, h2, "bar");
    const h3 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = true, .alignment = .right } });
    try doc.appendChild(header, h3);
    try addText(&doc, h3, "baz");

    // One body row: padded to the table's three columns (an empty cell
    // renders <td></td>).
    const body = try doc.createNode(.table_row, .{ .start = 0, .end = 0 }, .{ .table_row = .{} });
    try doc.appendChild(table, body);
    const b1 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = false, .alignment = .none } });
    try doc.appendChild(body, b1);
    try addText(&doc, b1, "quux");
    const b2 = try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = false, .alignment = .center } });
    try doc.appendChild(body, b2);
    try doc.appendChild(body, try doc.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = false, .alignment = .right } }));

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<table>\n<thead>\n<tr>\n<th>foo</th>\n<th align=\"center\">bar</th>\n<th align=\"right\">baz</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>quux</td>\n<td align=\"center\"></td>\n<td align=\"right\"></td>\n</tr>\n</tbody>\n</table>\n",
        out.items,
    );

    // No body rows: no <tbody> section is emitted.
    var doc2 = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc2.deinit();
    const t2 = try doc2.createNode(.table, .{ .start = 0, .end = 0 }, .{ .table = .{ .alignment = &.{.none}, .sections = true } });
    try doc2.appendChild(doc2.root, t2);
    const h = try doc2.createNode(.table_row, .{ .start = 0, .end = 0 }, .{ .table_row = .{} });
    try doc2.appendChild(t2, h);
    const c = try doc2.createNode(.table_cell, .{ .start = 0, .end = 0 }, .{ .table_cell = .{ .header = true, .alignment = .none } });
    try doc2.appendChild(h, c);
    try addText(&doc2, c, "only");
    var out2 = try renderDoc(&doc2);
    defer out2.deinit(testing.allocator);
    try testing.expectEqualStrings("<table>\n<thead>\n<tr>\n<th>only</th>\n</tr>\n</thead>\n</table>\n", out2.items);
}

test "html: thematic break follows the void-element profile" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "***" });
    defer doc.deinit();
    try doc.appendChild(doc.root, try doc.createNode(.thematic_break, .{ .start = 0, .end = 3 }, .none));

    var default_out = try renderDoc(&doc);
    defer default_out.deinit(testing.allocator);
    try testing.expectEqualStrings("<hr />\n", default_out.items);

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try render(testing.allocator, &aw.writer, &doc, .{ .void_trailing_slash = false });
    var modern_out = aw.toArrayList();
    defer modern_out.deinit(testing.allocator);
    try testing.expectEqualStrings("<hr>\n", modern_out.items);
}

test "html: xhtml profile always uses the XML void form" {
    // The XHTML profile forces the empty-element trailing slash even when
    // the HTML-mode option would emit the HTML5 bare form.
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    try doc.appendChild(p, try doc.createNode(.hard_break, .{ .start = 0, .end = 0 }, .none));
    try doc.appendChild(doc.root, try doc.createNode(.thematic_break, .{ .start = 0, .end = 0 }, .none));
    try doc.appendChild(p, try doc.createNode(.image, .{ .start = 0, .end = 0 }, .{
        .image = .{ .src = "/u", .alt = "a", .title = null },
    }));

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try render(testing.allocator, &aw.writer, &doc, .{ .void_trailing_slash = false, .profile = .xhtml });
    var out = aw.toArrayList();
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<p><br />\n<img src=\"/u\" alt=\"a\" /></p>\n<hr />\n", out.items);
}

test "html: xhtml profile rejects raw HTML leaves fail-closed" {
    // Inline raw_html: the source bytes are emitted verbatim in HTML mode
    // and must fail in XHTML mode.
    {
        const input = "<b>hi</b>";
        var doc = try document.Document.init(testing.allocator, .{ .bytes = input });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = @intCast(input.len) }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.raw_html, .{ .start = 0, .end = @intCast(input.len) }, .none));

        var html_out = try renderDoc(&doc);
        defer html_out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p><b>hi</b></p>\n", html_out.items);

        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try testing.expectError(RawHtmlNotXmlWellFormed, render(testing.allocator, &aw.writer, &doc, .{ .profile = .xhtml }));
    }
    // Block html_block: same fail-closed contract.
    {
        const input = "<div>\nx\n</div>";
        var doc = try document.Document.init(testing.allocator, .{ .bytes = input });
        defer doc.deinit();
        const html_block = try doc.createNode(.html_block, .{ .start = 0, .end = @intCast(input.len) }, .{ .html_block = input });
        try doc.appendChild(doc.root, html_block);

        var html_out = try renderDoc(&doc);
        defer html_out.deinit(testing.allocator);
        try testing.expectEqualStrings("<div>\nx\n</div>\n", html_out.items);

        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        try testing.expectError(RawHtmlNotXmlWellFormed, render(testing.allocator, &aw.writer, &doc, .{ .profile = .xhtml }));
    }
}

test "html: xhtml profile rejects Textile pre. verbatim code blocks" {
    // A `.code_block` with `escape == false` (Textile `pre.`) passes its
    // content through verbatim; the XHTML profile rejects it. Escaped code
    // blocks (`escape == true`) remain fine.
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    try doc.appendChild(doc.root, try doc.createNode(.code_block, .{ .start = 0, .end = 0 }, .{
        .code_block = .{ .content = "a < b", .escape = false },
    }));

    var html_out = try renderDoc(&doc);
    defer html_out.deinit(testing.allocator);
    try testing.expectEqualStrings("<pre>a < b</pre>\n", html_out.items);

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(RawHtmlNotXmlWellFormed, render(testing.allocator, &aw.writer, &doc, .{ .profile = .xhtml }));

    // Escaped code blocks render through the XHTML profile (escaped text is
    // XML-safe).
    var doc2 = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc2.deinit();
    try doc2.appendChild(doc2.root, try doc2.createNode(.code_block, .{ .start = 0, .end = 0 }, .{
        .code_block = .{ .content = "a < b & c", .info = "zig", .escape = true },
    }));
    var aw2 = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw2.deinit();
    try render(testing.allocator, &aw2.writer, &doc2, .{ .profile = .xhtml });
    var xhtml_out = aw2.toArrayList();
    defer xhtml_out.deinit(testing.allocator);
    try testing.expectEqualStrings("<pre><code class=\"language-zig\">a &lt; b &amp; c</code></pre>\n", xhtml_out.items);
}

test "html: xhtml output is deterministic and html mode is unchanged" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    try addText(&doc, p, "a & b < c \" d \u{1F600} e");
    const lnk = try doc.createNode(.link, .{ .start = 0, .end = 0 }, .{
        .link = .{ .href = "/my url\"&x", .title = "t & t" },
    });
    try doc.appendChild(p, lnk);
    try addText(&doc, lnk, "go");
    try doc.appendChild(doc.root, try doc.createNode(.thematic_break, .{ .start = 0, .end = 0 }, .none));

    // HTML mode: exactly today's bytes.
    var html_out = try renderDoc(&doc);
    defer html_out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<p>a &amp; b &lt; c &quot; d \u{1F600} e<a href=\"/my%20url%22&amp;x\" title=\"t &amp; t\">go</a></p>\n<hr />\n",
        html_out.items,
    );

    // XHTML mode: identical bytes here (escaping is already XML-safe), and
    // repeated renders are byte-identical.
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try render(testing.allocator, &aw.writer, &doc, .{ .profile = .xhtml });
    var first = aw.toArrayList();
    defer first.deinit(testing.allocator);
    var aw2 = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw2.deinit();
    try render(testing.allocator, &aw2.writer, &doc, .{ .profile = .xhtml });
    var second = aw2.toArrayList();
    defer second.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, first.items, second.items);
    try testing.expectEqualSlices(u8, html_out.items, first.items);
}

test "html: code block escapes content and uses the first info word" {
    const input = "``` zig&lang extra\n<x>\x00\n```";
    var doc = try document.Document.init(testing.allocator, .{ .bytes = input });
    defer doc.deinit();
    const code = try doc.createNode(.code_block, .{ .start = 0, .end = @intCast(input.len) }, .{
        .code_block = .{
            .content = "<x>\x00\n",
            .info = "zig&lang extra",
        },
    });
    try doc.appendChild(doc.root, code);

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<pre><code class=\"language-zig&amp;lang\">&lt;x&gt;\u{FFFD}\n</code></pre>\n",
        out.items,
    );
}

fn renderDocOpts(doc: *document.Document, options: RenderOptions) !std.ArrayList(u8) {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try render(testing.allocator, &aw.writer, doc, options);
    return aw.toArrayList();
}

fn addHeadingText(doc: *document.Document, h: *document.Node, text: []const u8) !void {
    try addText(doc, h, text);
}

test "html: heading ids slug the plain-text content and honor IAL ids" {
    {
        // Auto id from the heading's text (a code span contributes its
        // content; an entity decodes before slugging).
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const h = try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{ .heading = .{ .level = 1 } });
        try doc.appendChild(doc.root, h);
        try addText(&doc, h, "Hello, ");
        try doc.appendChild(h, try doc.createNode(.code_span, .{ .start = 0, .end = 0 }, .{ .code_span = "World" }));
        try addText(&doc, h, " &amp; Co!");
        var out = try renderDocOpts(&doc, .{ .heading_ids = true });
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<h1 id=\"hello-world-co\">Hello, <code>World</code> &amp; Co!</h1>\n", out.items);
    }
    {
        // An explicit IAL id wins over the slug; class is emitted.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const h = try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{
            .heading = .{ .level = 2, .id = "explicit", .class = "cls" },
        });
        try doc.appendChild(doc.root, h);
        try addHeadingText(&doc, h, "Whatever");
        var out = try renderDocOpts(&doc, .{ .heading_ids = true });
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<h2 id=\"explicit\" class=\"cls\">Whatever</h2>\n", out.items);
    }
    {
        // Without the option, no ids at all.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const h = try doc.createNode(.heading, .{ .start = 0, .end = 0 }, .{ .heading = .{ .level = 1 } });
        try doc.appendChild(doc.root, h);
        try addHeadingText(&doc, h, "Hello");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<h1>Hello</h1>\n", out.items);
    }
}

test "html: footnote refs and section render in first-reference order" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();

    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    try addText(&doc, p, "Hi");
    try doc.appendChild(p, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "second" } }));
    try addText(&doc, p, " and ");
    try doc.appendChild(p, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "syntax" } }));
    try addText(&doc, p, ".");

    // Definitions, in definition order (rendered in first-reference order).
    const def1 = try doc.createNode(.footnote, .{ .start = 0, .end = 0 }, .none);
    const p1 = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(def1, p1);
    try addText(&doc, p1, "First body");
    try doc.footnotes.append(doc.allocator(), .{ .label = "syntax", .node = def1 });

    const def2 = try doc.createNode(.footnote, .{ .start = 0, .end = 0 }, .none);
    const p2 = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(def2, p2);
    try addText(&doc, p2, "Second body");
    try doc.footnotes.append(doc.allocator(), .{ .label = "second", .node = def2 });

    var out = try renderDocOpts(&doc, .{ .footnotes = true });
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<p>Hi<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\" data-footnote-ref>1</a></sup> and <sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2\" data-footnote-ref>2</a></sup>.</p>\n" ++
            "<section class=\"footnotes\" data-footnotes>\n" ++
            "<ol>\n" ++
            "<li id=\"fn-1\">\n" ++
            "<p>Second body <a href=\"#fnref-1\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a></p>\n" ++
            "</li>\n" ++
            "<li id=\"fn-2\">\n" ++
            "<p>First body <a href=\"#fnref-2\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"2\" aria-label=\"Back to reference 2\">↩</a></p>\n" ++
            "</li>\n" ++
            "</ol>\n" ++
            "</section>\n",
        out.items,
    );

    // Without the option, refs with labels render literally.
    var out2 = try renderDoc(&doc);
    defer out2.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, out2.items, "footnote-ref") == null);
}

test "html: repeated footnote references get unique ids and one backref each" {
    // Regression (issue #44): every reference to the same footnote used
    // to emit the same `id="fnref-N"` (invalid HTML: duplicate ids break
    // getElementById and fragment navigation), and only the first
    // reference got a backref. The second reference to a footnote is now
    // `fnref-N-2`, the third `fnref-N-3`, and the footnote body emits one
    // backref per reference, each pointing at its own reference id.
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();

    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    try addText(&doc, p, "Alpha claim ");
    try doc.appendChild(p, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "a" } }));
    try addText(&doc, p, ". Beta claim ");
    try doc.appendChild(p, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "a" } }));
    try addText(&doc, p, ". Gamma claim ");
    try doc.appendChild(p, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "a" } }));
    try addText(&doc, p, ".");

    const p2 = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p2);
    try addText(&doc, p2, "Delta claim ");
    try doc.appendChild(p2, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "b" } }));
    try addText(&doc, p2, ". Epsilon claim ");
    try doc.appendChild(p2, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "b" } }));
    try addText(&doc, p2, ".");

    const def_a = try doc.createNode(.footnote, .{ .start = 0, .end = 0 }, .none);
    const pa = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(def_a, pa);
    try addText(&doc, pa, "First source");
    try doc.footnotes.append(doc.allocator(), .{ .label = "a", .node = def_a });

    const def_b = try doc.createNode(.footnote, .{ .start = 0, .end = 0 }, .none);
    const pb = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(def_b, pb);
    try addText(&doc, pb, "Second source");
    try doc.footnotes.append(doc.allocator(), .{ .label = "b", .node = def_b });

    var out = try renderDocOpts(&doc, .{ .footnotes = true });
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<p>Alpha claim <sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\" data-footnote-ref>1</a></sup>. Beta claim <sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1-2\" data-footnote-ref>1</a></sup>. Gamma claim <sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1-3\" data-footnote-ref>1</a></sup>.</p>\n" ++
            "<p>Delta claim <sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2\" data-footnote-ref>2</a></sup>. Epsilon claim <sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2-2\" data-footnote-ref>2</a></sup>.</p>\n" ++
            "<section class=\"footnotes\" data-footnotes>\n" ++
            "<ol>\n" ++
            "<li id=\"fn-1\">\n" ++
            "<p>First source <a href=\"#fnref-1\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a> <a href=\"#fnref-1-2\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1-2\" aria-label=\"Back to reference 1-2\">↩</a> <a href=\"#fnref-1-3\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1-3\" aria-label=\"Back to reference 1-3\">↩</a></p>\n" ++
            "</li>\n" ++
            "<li id=\"fn-2\">\n" ++
            "<p>Second source <a href=\"#fnref-2\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"2\" aria-label=\"Back to reference 2\">↩</a> <a href=\"#fnref-2-2\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"2-2\" aria-label=\"Back to reference 2-2\">↩</a></p>\n" ++
            "</li>\n" ++
            "</ol>\n" ++
            "</section>\n",
        out.items,
    );

    // Every reference id is unique: the fnref- prefix never repeats.
    var count: usize = 0;
    for (out.items, 0..) |_, i| {
        if (std.mem.startsWith(u8, out.items[i..], "id=\"fnref-")) count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
}

test "html: XHTML profile writes footnote valueless attributes with empty values" {
    // Regression (issue #60): footnote markers emitted valueless data-*
    // attributes (`data-footnote-ref`, `data-footnotes`,
    // `data-footnote-backref`), which are not XML-well-formed, so an
    // XHTML-rendered document containing footnotes was invalid XML. Under
    // `.xhtml` the valueless forms serialize with explicit empty values;
    // the HTML profile output is byte-unchanged (sibling tests above).
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();

    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(doc.root, p);
    try addText(&doc, p, "Hi");
    try doc.appendChild(p, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "second" } }));
    try addText(&doc, p, " and ");
    try doc.appendChild(p, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "syntax" } }));
    try addText(&doc, p, ".");

    const def1 = try doc.createNode(.footnote, .{ .start = 0, .end = 0 }, .none);
    const p1 = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(def1, p1);
    try addText(&doc, p1, "First body");
    try doc.footnotes.append(doc.allocator(), .{ .label = "syntax", .node = def1 });

    const def2 = try doc.createNode(.footnote, .{ .start = 0, .end = 0 }, .none);
    const p2 = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(def2, p2);
    try addText(&doc, p2, "Second body");
    try doc.footnotes.append(doc.allocator(), .{ .label = "second", .node = def2 });

    var out = try renderDocOpts(&doc, .{ .footnotes = true, .profile = .xhtml });
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "<p>Hi<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\" data-footnote-ref=\"\">1</a></sup> and <sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2\" data-footnote-ref=\"\">2</a></sup>.</p>\n" ++
            "<section class=\"footnotes\" data-footnotes=\"\">\n" ++
            "<ol>\n" ++
            "<li id=\"fn-1\">\n" ++
            "<p>Second body <a href=\"#fnref-1\" class=\"footnote-backref\" data-footnote-backref=\"\" data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a></p>\n" ++
            "</li>\n" ++
            "<li id=\"fn-2\">\n" ++
            "<p>First body <a href=\"#fnref-2\" class=\"footnote-backref\" data-footnote-backref=\"\" data-footnote-backref-idx=\"2\" aria-label=\"Back to reference 2\">↩</a></p>\n" ++
            "</li>\n" ++
            "</ol>\n" ++
            "</section>\n",
        out.items,
    );

    // The bare valueless forms must not appear under XHTML.
    try testing.expect(std.mem.indexOf(u8, out.items, "data-footnote-ref>") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "data-footnotes>") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "data-footnote-backref ") == null);
}

test "html: render without footnote context never frees an uninitialized map" {
    // Regression: the footnote-numbering table was left `undefined` whenever
    // the footnotes option was off (or on with no definitions), yet `deinit`
    // ran unconditionally. Freeing an uninitialized managed HashMap reads the
    // garbage `pointer_stability` mutex and aborts on platforms/stack states
    // where that garbage is non-zero (observed on Linux CI; benign on macOS).
    // Every render path must construct the map with a real allocator.
    {
        // Default options, no footnotes anywhere.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try addText(&doc, p, "No footnotes here.");
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>No footnotes here.</p>\n", out.items);
    }
    {
        // Option enabled but the document defines no footnotes.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try addText(&doc, p, "Plain paragraph.");
        var out = try renderDocOpts(&doc, .{ .footnotes = true });
        defer out.deinit(testing.allocator);
        try testing.expectEqualStrings("<p>Plain paragraph.</p>\n", out.items);
    }
    {
        // Definitions present but the option off: refs render literally and
        // the numbering table is still the empty-initialized path.
        var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
        defer doc.deinit();
        const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
        try doc.appendChild(doc.root, p);
        try doc.appendChild(p, try doc.createNode(.footnote_ref, .{ .start = 0, .end = 0 }, .{ .footnote_ref = .{ .label = "x" } }));
        const def = try doc.createNode(.footnote, .{ .start = 0, .end = 0 }, .none);
        try doc.footnotes.append(doc.allocator(), .{ .label = "x", .node = def });
        var out = try renderDoc(&doc);
        defer out.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, out.items, "footnote-ref") == null);
    }
}

test "html: definition lists render dl/dt/dd with tight single paragraphs" {
    var doc = try document.Document.init(testing.allocator, .{ .bytes = "" });
    defer doc.deinit();

    const dl = try doc.createNode(.definition_list, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(doc.root, dl);

    const dt = try doc.createNode(.definition_term, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(dl, dt);
    try addText(&doc, dt, "Term");

    const dd = try doc.createNode(.definition_body, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(dl, dd);
    const p = try doc.createNode(.paragraph, .{ .start = 0, .end = 0 }, .{ .paragraph = .{} });
    try doc.appendChild(dd, p);
    try addText(&doc, p, "Definition");

    var out = try renderDoc(&doc);
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("<dl>\n<dt>Term</dt>\n<dd>Definition</dd>\n</dl>\n", out.items);
}
