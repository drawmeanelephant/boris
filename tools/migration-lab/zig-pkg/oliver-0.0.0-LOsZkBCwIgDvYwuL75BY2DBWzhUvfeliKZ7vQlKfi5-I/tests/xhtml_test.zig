//! XHTML output profile tests (docs/XHTML.md).
//!
//! Coverage:
//!   - paired HTML/XHTML expectations for representative structures
//!   - explicit assertions that default HTML output is unchanged (byte-equal
//!     to the committed markdown fixtures)
//!   - fail-closed raw-HTML / Textile `pre.` rejection under XHTML
//!   - deterministic repeated output
//!   - a mechanical well-formedness gate over representative XHTML output
//!     (tests/xhtml_wellformed.zig)
//!
//! The profile contract in one line: same IR, same semantics, different
//! serialization bytes. Where HTML and XHTML agree byte-for-byte (the
//! default serializer already emits XML-style voids and the XML predefined
//! escapes), the fixtures document that agreement explicitly.

const std = @import("std");
const oliver = @import("oliver");
const wellformed = @import("xhtml_wellformed.zig");

fn renderProfile(
    input: []const u8,
    dialect: oliver.Dialect,
    profile: oliver.OutputProfile,
) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, dialect, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{ .profile = profile });
    return aw.toArrayList();
}

fn renderHtml(input: []const u8, dialect: oliver.Dialect) !std.ArrayList(u8) {
    return renderProfile(input, dialect, .html);
}

fn renderXhtml(input: []const u8, dialect: oliver.Dialect) !std.ArrayList(u8) {
    return renderProfile(input, dialect, .xhtml);
}

fn expectRender(actual: []const u8, expected: []const u8, label: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print(
            "{s} mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
            .{ label, expected.len, expected, actual.len, actual },
        );
        return error.FixtureMismatch;
    }
}

/// Asserts the XHTML output is byte-identical to the HTML output for inputs
/// whose serialization the profile does not change (the XML-predefined
/// escapes and XML-style voids are already the default). This is the
/// strongest form of the "HTML mode has not changed" claim: any divergence
/// would mean the profile leaked into shared serialization.
fn expectAgree(input: []const u8, dialect: oliver.Dialect) !void {
    var html = try renderHtml(input, dialect);
    defer html.deinit(std.testing.allocator);
    var xhtml = try renderXhtml(input, dialect);
    defer xhtml.deinit(std.testing.allocator);
    try expectRender(xhtml.items, html.items, "xhtml vs html");
}

fn renderCooklangProfile(input: []const u8, profile: oliver.OutputProfile) !std.ArrayList(u8) {
    var result = try oliver.cooklang.parse(std.testing.allocator, input, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.cooklang_html.render(std.testing.allocator, &aw.writer, &result.recipe, .{ .profile = profile });
    return aw.toArrayList();
}

fn wrapFragment(fragment: []const u8, out: *std.ArrayList(u8)) !void {
    // The wrapper belongs to the TEST only (docs/XHTML.md §"Well-formedness
    // gate"): Oliver fragments never gain document wrappers.
    try out.appendSlice(std.testing.allocator, "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>");
    try out.appendSlice(std.testing.allocator, fragment);
    try out.appendSlice(std.testing.allocator, "</body></html>");
}

// ---------------------------------------------------------------------------
// Paired fixtures: input -> expected HTML (reference) and expected XHTML.
// The differences are exactly the serialization deltas the profile owns.
// ---------------------------------------------------------------------------

const Pair = struct {
    name: []const u8,
    dialect: oliver.Dialect,
    input: []const u8,
    html: []const u8,
    xhtml: []const u8,
};

const markdown_pairs = [_]Pair{
    .{
        .name = "paragraph",
        .dialect = .markdown,
        .input = "Hello, world.\n",
        .html = "<p>Hello, world.</p>\n",
        .xhtml = "<p>Hello, world.</p>\n",
    },
    .{
        .name = "headings",
        .dialect = .markdown,
        .input = "# One\n\n## Two\n",
        .html = "<h1>One</h1>\n<h2>Two</h2>\n",
        .xhtml = "<h1>One</h1>\n<h2>Two</h2>\n",
    },
    .{
        .name = "emphasis-strong",
        .dialect = .markdown,
        .input = "*em* and **strong**\n",
        .html = "<p><em>em</em> and <strong>strong</strong></p>\n",
        .xhtml = "<p><em>em</em> and <strong>strong</strong></p>\n",
    },
    .{
        .name = "link-escaped-attr",
        .dialect = .markdown,
        .input = "[a &quot;quoted&quot; &amp; x](/u?a=1&amp;b=2 \"t\\\"itle\")\n",
        .html = "<p><a href=\"/u?a=1&amp;b=2\" title=\"t&quot;itle\">a &quot;quoted&quot; &amp; x</a></p>\n",
        .xhtml = "<p><a href=\"/u?a=1&amp;b=2\" title=\"t&quot;itle\">a &quot;quoted&quot; &amp; x</a></p>\n",
    },
    .{
        .name = "image",
        .dialect = .markdown,
        .input = "![alt \\\"x\\\"](img.png \"title\")\n",
        .html = "<p><img src=\"img.png\" alt=\"alt &quot;x&quot;\" title=\"title\" /></p>\n",
        .xhtml = "<p><img src=\"img.png\" alt=\"alt &quot;x&quot;\" title=\"title\" /></p>\n",
    },
    .{
        .name = "hard-break",
        .dialect = .markdown,
        .input = "foo\\\nbar\n",
        .html = "<p>foo<br />\nbar</p>\n",
        .xhtml = "<p>foo<br />\nbar</p>\n",
    },
    .{
        .name = "thematic-break",
        .dialect = .markdown,
        .input = "***\n",
        .html = "<hr />\n",
        .xhtml = "<hr />\n",
    },
    .{
        .name = "inline-code",
        .dialect = .markdown,
        .input = "`a < b & c`\n",
        .html = "<p><code>a &lt; b &amp; c</code></p>\n",
        .xhtml = "<p><code>a &lt; b &amp; c</code></p>\n",
    },
    .{
        .name = "fenced-code",
        .dialect = .markdown,
        .input = "```\n*raw* & <tag>\n```\n",
        .html = "<pre><code>*raw* &amp; &lt;tag&gt;\n</code></pre>\n",
        .xhtml = "<pre><code>*raw* &amp; &lt;tag&gt;\n</code></pre>\n",
    },
    .{
        .name = "blockquote",
        .dialect = .markdown,
        .input = "> quoted\n",
        .html = "<blockquote>\n<p>quoted</p>\n</blockquote>\n",
        .xhtml = "<blockquote>\n<p>quoted</p>\n</blockquote>\n",
    },
    .{
        .name = "lists",
        .dialect = .markdown,
        .input = "- a\n- b\n\n1. one\n2. two\n",
        .html = "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n",
        .xhtml = "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n",
    },
    .{
        .name = "nested-list",
        .dialect = .markdown,
        .input = "- a\n  - b\n",
        .html = "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n",
        .xhtml = "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n",
    },
    .{
        .name = "table",
        .dialect = .markdown,
        .input = "| foo | bar |\n| --- | --- |\n| baz | bim |\n",
        .html = "<table>\n<thead>\n<tr>\n<th>foo</th>\n<th>bar</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>baz</td>\n<td>bim</td>\n</tr>\n</tbody>\n</table>\n",
        .xhtml = "<table>\n<thead>\n<tr>\n<th>foo</th>\n<th>bar</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>baz</td>\n<td>bim</td>\n</tr>\n</tbody>\n</table>\n",
    },
    .{
        .name = "unicode",
        .dialect = .markdown,
        .input = "café — 日本語 😀\n",
        .html = "<p>café — 日本語 😀</p>\n",
        .xhtml = "<p>café — 日本語 😀</p>\n",
    },
};

const textile_pairs = [_]Pair{
    .{
        .name = "phrase-attrs",
        .dialect = .textile,
        .input = "*(class)em* and _(class#id)em_\n",
        .html = "<p><strong class=\"class\">em</strong> and <em class=\"class\" id=\"id\">em</em></p>\n",
        .xhtml = "<p><strong class=\"class\">em</strong> and <em class=\"class\" id=\"id\">em</em></p>\n",
    },
    .{
        .name = "table-textile",
        .dialect = .textile,
        .input = "|_. h1 |_. h2 |\n| a | b |\n",
        .html = "<table>\n<tr>\n<th>h1 </th>\n<th>h2 </th>\n</tr>\n<tr>\n<td> a </td>\n<td> b </td>\n</tr>\n</table>\n",
        .xhtml = "<table>\n<tr>\n<th>h1 </th>\n<th>h2 </th>\n</tr>\n<tr>\n<td> a </td>\n<td> b </td>\n</tr>\n</table>\n",
    },
};

test "xhtml: markdown paired fixtures" {
    for (markdown_pairs) |p| {
        var html = try renderHtml(p.input, p.dialect);
        defer html.deinit(std.testing.allocator);
        try expectRender(html.items, p.html, p.name);
        var xhtml = try renderXhtml(p.input, p.dialect);
        defer xhtml.deinit(std.testing.allocator);
        try expectRender(xhtml.items, p.xhtml, p.name);
    }
}

test "xhtml: textile paired fixtures" {
    for (textile_pairs) |p| {
        var html = try renderHtml(p.input, p.dialect);
        defer html.deinit(std.testing.allocator);
        try expectRender(html.items, p.html, p.name);
        var xhtml = try renderXhtml(p.input, p.dialect);
        defer xhtml.deinit(std.testing.allocator);
        try expectRender(xhtml.items, p.xhtml, p.name);
    }
}

// ---------------------------------------------------------------------------
// HTML mode has NOT changed: the committed markdown fixtures (the reference
// output) must still render byte-identically through the default profile.
// The XHTML profile must agree with them wherever it owns no serialization
// delta. (The full fixture wall runs in fixtures_test.zig; these are the
// XHTML-adjacent representatives.)
// ---------------------------------------------------------------------------

const HtmlRef = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
};

const html_refs = [_]HtmlRef{
    .{ .name = "fence-basic", .input = @embedFile("fixtures/markdown/fence-basic.md"), .expected = @embedFile("fixtures/markdown/fence-basic.html") },
    .{ .name = "table-basic", .input = @embedFile("fixtures/markdown/table-basic.md"), .expected = @embedFile("fixtures/markdown/table-basic.html") },
    .{ .name = "hard-break-backslash", .input = @embedFile("fixtures/markdown/hard-break-backslash.md"), .expected = @embedFile("fixtures/markdown/hard-break-backslash.html") },
    .{ .name = "image-title", .input = @embedFile("fixtures/markdown/image-title.md"), .expected = @embedFile("fixtures/markdown/image-title.html") },
    .{ .name = "link-titles", .input = @embedFile("fixtures/markdown/link-titles.md"), .expected = @embedFile("fixtures/markdown/link-titles.html") },
};

test "xhtml: HTML reference output unchanged; XHTML agrees on clean content" {
    for (html_refs) |r| {
        var html = try renderHtml(r.input, .markdown);
        defer html.deinit(std.testing.allocator);
        try expectRender(html.items, r.expected, r.name);
        var xhtml = try renderXhtml(r.input, .markdown);
        defer xhtml.deinit(std.testing.allocator);
        try expectRender(xhtml.items, r.expected, r.name);
    }
}

test "xhtml: Cooklang HTML unchanged; XHTML switches the line break" {
    const input =
        \\Take the pan @pan{} and simmer \
        \\on low.
        \\
    ;
    // The HTML reference output is what the Cooklang fixtures wall asserts
    // (renderCooklangHtml with default options); the only XHTML delta is the
    // `<br>` -> `<br />` serialization of a forced line break.
    var html = try renderCooklangProfile(input, .html);
    defer html.deinit(std.testing.allocator);
    var xhtml = try renderCooklangProfile(input, .xhtml);
    defer xhtml.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, html.items, "<br>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.items, "<br />") == null);
    try std.testing.expect(std.mem.indexOf(u8, xhtml.items, "<br />") != null);
    try std.testing.expect(std.mem.indexOf(u8, xhtml.items, "<br>") == null);

    // Everything else in the fragment is byte-identical between profiles:
    // substituting the one serialization delta yields the XHTML output.
    const expected = try std.mem.replaceOwned(u8, std.testing.allocator, html.items, "<br>", "<br />");
    defer std.testing.allocator.free(expected);
    try expectRender(xhtml.items, expected, "cooklang xhtml vs html+br-delta");
}

// ---------------------------------------------------------------------------
// Fail-closed raw HTML policy (docs/XHTML.md §"Raw HTML policy").
// ---------------------------------------------------------------------------

const RawCase = struct {
    name: []const u8,
    dialect: oliver.Dialect,
    input: []const u8,
};

const raw_cases = [_]RawCase{
    // Markdown raw HTML: inline and block leaves pass through in HTML mode.
    .{ .name = "inline-raw", .dialect = .markdown, .input = "before <span class=\"x\">raw</span> after\n" },
    .{ .name = "block-raw", .dialect = .markdown, .input = "<div>\n<p>raw block</p>\n</div>\n" },
    // Textile `pre.` renders its source verbatim inside <pre>.
    .{ .name = "textile-pre", .dialect = .textile, .input = "pre. <b>not parsed</b>\n" },
};

test "xhtml: HTML accepts raw content; XHTML fails closed" {
    for (raw_cases) |c| {
        var html = try renderHtml(c.input, c.dialect);
        defer html.deinit(std.testing.allocator);
        try std.testing.expect(html.items.len > 0);

        var result = try oliver.parse(std.testing.allocator, c.input, c.dialect, .{});
        defer result.deinit();
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try std.testing.expectError(
            error.RawHtmlNotXmlWellFormed,
            oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{ .profile = .xhtml }),
        );
    }
}

// ---------------------------------------------------------------------------
// Determinism: same input, same profile -> byte-identical output.
// ---------------------------------------------------------------------------

test "xhtml: repeated rendering is byte-identical" {
    const kitchen_sink =
        \\# Title
        \\
        \\A paragraph with *em*, **strong**, `code`, a [link](https://example.com "t"),
        \\an image ![alt](img.png), a hard break\
        \\and a soft break
        \\with continuation.
        \\
        \\> a quote
        \\
        \\- one
        \\- two
        \\  - nested
        \\
        \\1. first
        \\2. second
        \\
        \\| a | b |
        \\| --- | --- |
        \\| c | d |
        \\
        \\```zig
        \\const x: u8 = 1;
        \\```
        \\
        \\café — 日本語 😀 & < > " '
        \\
    ;
    for ([_]oliver.OutputProfile{ .html, .xhtml }) |profile| {
        var once = try renderProfile(kitchen_sink, .markdown, profile);
        defer once.deinit(std.testing.allocator);
        var twice = try renderProfile(kitchen_sink, .markdown, profile);
        defer twice.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, once.items, twice.items);
    }
}

// ---------------------------------------------------------------------------
// Well-formedness gate: representative XHTML output is mechanically valid
// XML. The wrapper is test-only (docs/XHTML.md §"Well-formedness gate").
// ---------------------------------------------------------------------------

test "xhtml: representative output is well-formed XML" {
    const markdown_kitchen =
        \\# Heading
        \\
        \\*em* **strong** `code` [link](/u?a=1&amp;b=2 "t\"itle")
        \\![alt](/img.png "title")
        \\
        \\> quoted
        \\
        \\- a
        \\  - b
        \\- c
        \\
        \\1. one
        \\2. two
        \\
        \\| x | y |
        \\| --- | --- |
        \\| 1 | 2 |
        \\
        \\```
        \\<not markup> & "quoted"
        \\```
        \\
        \\---
        \\
        \\café — 日本語 😀
        \\
    ;
    const textile_kitchen =
        \\h1. Título
        \\
        \\*em* **strong** %(class)span% _(class#id)em_ [link](https://e.test "t")
        \\|_. a |_. b |
        \\| 1 | 2 |
        \\
    ;

    var xhtml_md = try renderXhtml(markdown_kitchen, .markdown);
    defer xhtml_md.deinit(std.testing.allocator);
    var wrapped_md = std.ArrayList(u8).empty;
    defer wrapped_md.deinit(std.testing.allocator);
    try wrapFragment(xhtml_md.items, &wrapped_md);
    try wellformed.check(wrapped_md.items);

    var xhtml_tx = try renderXhtml(textile_kitchen, .textile);
    defer xhtml_tx.deinit(std.testing.allocator);
    var wrapped_tx = std.ArrayList(u8).empty;
    defer wrapped_tx.deinit(std.testing.allocator);
    try wrapFragment(xhtml_tx.items, &wrapped_tx);
    try wellformed.check(wrapped_tx.items);

    var xhtml_ck = try renderCooklangProfile(
        "Take @pan{} and simmer \\\non low. Add @salt{1 tsp}.\n",
        .xhtml,
    );
    defer xhtml_ck.deinit(std.testing.allocator);
    var wrapped_ck = std.ArrayList(u8).empty;
    defer wrapped_ck.deinit(std.testing.allocator);
    try wrapFragment(xhtml_ck.items, &wrapped_ck);
    try wellformed.check(wrapped_ck.items);

    // NUL-bearing Cooklang: the renderer must replace NUL with U+FFFD
    // (issue #56) — a raw NUL would be invalid XML, so this case would
    // fail the well-formedness gate if the replacement regressed.
    var xhtml_ck_nul = try renderCooklangProfile("Add @salt \x00 NUL in text.\n", .xhtml);
    defer xhtml_ck_nul.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOfScalar(u8, xhtml_ck_nul.items, 0) == null);
    var wrapped_ck_nul = std.ArrayList(u8).empty;
    defer wrapped_ck_nul.deinit(std.testing.allocator);
    try wrapFragment(xhtml_ck_nul.items, &wrapped_ck_nul);
    try wellformed.check(wrapped_ck_nul.items);

    // Footnote machinery must stay XML-well-formed: the valueless data-*
    // attributes serialize with explicit empty values under XHTML
    // (issue #60) — a bare attribute would fail the gate below. The
    // repeated reference also exercises the `-2` backref-id format.
    const footnote_input =
        \\Reference[^1] and repeat[^1] and another[^2].
        \\
        \\[^1]: First body.
        \\[^2]: Second body.
        \\
    ;
    var fn_result = try oliver.parse(std.testing.allocator, footnote_input, .markdown, .{ .markdown = .{ .footnotes = true } });
    defer fn_result.deinit();
    var fn_aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer fn_aw.deinit();
    try oliver.html.render(std.testing.allocator, &fn_aw.writer, &fn_result.document, .{ .profile = .xhtml, .footnotes = true });
    var fn_frag = fn_aw.toArrayList();
    defer fn_frag.deinit(std.testing.allocator);
    var wrapped_fn = std.ArrayList(u8).empty;
    defer wrapped_fn.deinit(std.testing.allocator);
    try wrapFragment(fn_frag.items, &wrapped_fn);
    try wellformed.check(wrapped_fn.items);
}

test "xhtml: wellformedness checker itself distinguishes clean from poisoned" {
    const clean = "<p>a &amp; b</p>";
    var wrapped = std.ArrayList(u8).empty;
    defer wrapped.deinit(std.testing.allocator);
    try wrapFragment(clean, &wrapped);
    try wellformed.check(wrapped.items);

    // A raw-HTML fragment smuggled past the fail-closed gate would be caught
    // here: unescaped angle brackets in text are not well-formed XML.
    const poisoned = "<p>a <b> raw </p>";
    var wrapped_bad = std.ArrayList(u8).empty;
    defer wrapped_bad.deinit(std.testing.allocator);
    try wrapFragment(poisoned, &wrapped_bad);
    try std.testing.expectError(error.Malformed, wellformed.check(wrapped_bad.items));
}

fn renderWikilinkProfile(
    input: []const u8,
    profile: oliver.OutputProfile,
    resolver: ?oliver.html.WikilinkResolver,
) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, .markdown, .{
        .markdown = .{ .wikilinks = true },
    });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{
        .profile = profile,
        .wikilink_resolver = resolver,
    });
    return aw.toArrayList();
}

fn testXhtmlWikilinkResolver(_: []const u8, label: ?[]const u8, _: ?*const anyopaque) oliver.html.ResolvedWikilink {
    return .{ .href = "/notes", .text = label orelse "untitled" };
}

test "xhtml: wikilinks are well-formed under both profiles (extension)" {
    const input = "See [[Page Name]] and [[Page Name|Custom Label]], plus [[note]] here.\n";
    var html = try renderWikilinkProfile(input, .html, null);
    defer html.deinit(std.testing.allocator);
    var xhtml = try renderWikilinkProfile(input, .xhtml, null);
    defer xhtml.deinit(std.testing.allocator);
    // No serialization delta: the profiles agree byte-for-byte.
    try expectRender(xhtml.items, html.items, "wikilinks xhtml vs html");
    var wrapped = std.ArrayList(u8).empty;
    defer wrapped.deinit(std.testing.allocator);
    try wrapFragment(xhtml.items, &wrapped);
    try wellformed.check(wrapped.items);

    // A consumer resolver must also stay well-formed.
    var resolved = try renderWikilinkProfile("[[Page Name|Label]]\n", .xhtml, &testXhtmlWikilinkResolver);
    defer resolved.deinit(std.testing.allocator);
    try expectRender(resolved.items, "<p><a href=\"/notes\">Label</a></p>\n", "wikilinks resolver xhtml");
    var wrapped_r = std.ArrayList(u8).empty;
    defer wrapped_r.deinit(std.testing.allocator);
    try wrapFragment(resolved.items, &wrapped_r);
    try wellformed.check(wrapped_r.items);
}

fn renderFrontmatterProfile(input: []const u8, profile: oliver.OutputProfile) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, .markdown, .{ .frontmatter = .yaml });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{ .profile = profile });
    return aw.toArrayList();
}

test "xhtml: frontmatter body is well-formed under both profiles (extension)" {
    // The strip happens before parsing, so the fence and payload never
    // reach the renderer; the body must stay well-formed under `.xhtml`
    // like any other markdown (docs/FRONTMATTER.md §10).
    const input = "---\ntitle: \"A & B\"\n---\n\n# Doc\n\nSee [a & b](/x?a=1&b=2).\n";
    var html = try renderFrontmatterProfile(input, .html);
    defer html.deinit(std.testing.allocator);
    var xhtml = try renderFrontmatterProfile(input, .xhtml);
    defer xhtml.deinit(std.testing.allocator);
    try expectRender(xhtml.items, html.items, "frontmatter xhtml vs html");
    var wrapped = std.ArrayList(u8).empty;
    defer wrapped.deinit(std.testing.allocator);
    try wrapFragment(xhtml.items, &wrapped);
    try wellformed.check(wrapped.items);
}

fn renderCalloutProfile(input: []const u8, profile: oliver.OutputProfile) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, .markdown, .{
        .markdown = .{ .callouts = true },
    });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{ .profile = profile });
    return aw.toArrayList();
}

test "xhtml: callouts are well-formed under both profiles (extension)" {
    // The `<div class="callout ...">` wrapper replaces the blockquote
    // element, so it must stay balanced and well-formed under `.xhtml`
    // like any other container (docs/CALLOUTS.md §5).
    const input = "\n> [!note] A & B title\n> Body with *emphasis* and [a & b](/x?a=1&b=2).\n";
    var html = try renderCalloutProfile(input, .html);
    defer html.deinit(std.testing.allocator);
    var xhtml = try renderCalloutProfile(input, .xhtml);
    defer xhtml.deinit(std.testing.allocator);
    try expectRender(xhtml.items, html.items, "callout xhtml vs html");
    var wrapped = std.ArrayList(u8).empty;
    defer wrapped.deinit(std.testing.allocator);
    try wrapFragment(xhtml.items, &wrapped);
    try wellformed.check(wrapped.items);
}

fn renderSmartypantsProfile(input: []const u8, profile: oliver.OutputProfile) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, .markdown, .{
        .markdown = .{ .smartypants = true },
    });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{ .profile = profile });
    return aw.toArrayList();
}

test "xhtml: smartypants output is well-formed under both profiles (extension)" {
    // The pass replaces payload bytes with Unicode punctuation and
    // symbols — no new elements or attributes — so the output must stay
    // well-formed under `.xhtml` like any other text (docs/SMARTY.md §4).
    const input = "\"Hello,\" -- she said... And 2 x 4 with (c) and a [l\"ink\"](/x?a=1&b=2).\n";
    var html = try renderSmartypantsProfile(input, .html);
    defer html.deinit(std.testing.allocator);
    var xhtml = try renderSmartypantsProfile(input, .xhtml);
    defer xhtml.deinit(std.testing.allocator);
    try expectRender(xhtml.items, html.items, "smartypants xhtml vs html");
    var wrapped = std.ArrayList(u8).empty;
    defer wrapped.deinit(std.testing.allocator);
    try wrapFragment(xhtml.items, &wrapped);
    try wellformed.check(wrapped.items);
}
