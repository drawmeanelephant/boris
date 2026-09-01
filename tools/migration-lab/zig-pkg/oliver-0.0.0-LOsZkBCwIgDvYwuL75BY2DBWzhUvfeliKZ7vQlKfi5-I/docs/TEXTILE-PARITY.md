---
published_at: 2026-08-13T00:00:00Z
summary: Textile has no normative corpus, so its quality bar is a fixture audit: the parity audit holds the frontend to documented expectations.
---

# Textile parity audit

Oliver's Markdown frontend is held to the 652-example CommonMark 0.31.2
conformance corpus. Textile has no comparable normative corpus, so its
quality bar is a **fixture audit**: every implemented feature is inventoried
against the shared document model, pinned by fixture pairs and unit tests,
and every gap against the published Textile 2 semantics is either closed or
recorded as a deliberate deferral. This document is that audit. It is
derived only from the clean-room sources of docs/CLEANROOM.md: the Hobix
**Textile Reference**, Movable Type's **Textile 2 Syntax**, and the current
Textile Markup Language Documentation. No parser implementation was
consulted.

## 1. Inventory: implemented Textile features vs. the shared model

| Textile syntax | shared node | HTML | status |
| --- | --- | --- | --- |
| `p.` marker / bare paragraph lines | `.paragraph` | `<p>` | implemented (T1) |
| `hN.` headings | `.heading` (level 1..6) | `<h1>`…`<h6>` | implemented (T1) |
| single-period `bq.` | `.block_quote` → `.paragraph` | `<blockquote><p>` | implemented (T1) |
| newline in a paragraph | `.hard_break` | `<br />` | implemented (T1) |
| `@code@` | `.code_span` (verbatim arena payload) | `<code>` | implemented (T2) |
| `*x*` strong | `.strong` | `<strong>` | implemented (T4) |
| `_x_` emphasis | `.emphasis` | `<em>` | implemented (T4) |
| `**x**` bold | `.bold` | `<b>` | implemented (T4) |
| `__x__` italic | `.italic` | `<i>` | implemented (T4) |
| `-x-` deleted | `.deleted` | `<del>` | implemented (T4) |
| `+x+` inserted | `.inserted` | `<ins>` | implemented (T4) |
| `^x^` superscript | `.superscript` | `<sup>` | implemented (T4) |
| `~x~` subscript | `.subscript` | `<sub>` | implemented (T4) |
| `%x%` span | `.span` | `<span>` | implemented (T4) |
| `"text":url` link | `.link` (arena href/title) | `<a href title>` | implemented (T4) |
| `"text (title)":url` link | `.link` (+ title) | `<a href title>` | implemented (T4) |
| `!url!` image | `.image` (src, alt `""`) | `<img src alt />` | implemented (T4) |
| `!url(alt)!` / `!url (alt)!` image | `.image` (src, alt, title) | `<img src alt title />` | implemented (T4) |
| `!url!:href` linked image | `.link` → `.image` | `<a><img /></a>` | implemented (T4) |
| `*` bullet lists | `.list` (bullet) → `.list_item` → `.paragraph` | `<ul><li>` | implemented (T4) |
| `#` ordered lists | `.list` (ordered) → `.list_item` → `.paragraph` | `<ol><li>` | implemented (T4) |
| marker-depth nesting (`**`, `##`) | nested `.list` inside `.list_item` | nested `<ul>`/`<ol>` | implemented (T4) |
| `|a|b|` rows | `.table` → `.table_row` → `.table_cell` | flat `<table><tr><td>` | implemented (T8) |
| `|_. header|` cells / `_`-marked rows | header cells (`<th>`) | `<th>` | implemented (T8) |
| cell modifiers (`<`, `>`, `=`, `<>`, `^`, `~`, `{style}`, `(class#id)`, `[lang]`, padding) | cell `attrs` (style/class/id/lang) | `<td style="…">` | implemented (T8) |
| `\2` colspan / `/2` rowspan | cell `colspan`/`rowspan` | `colspan="2"`/`rowspan="2"` | implemented (T8) |
| `table<mods>.` signature | table `attrs` | `<table style="…" class="…">` | implemented (T8) |
| row modifiers (incl. `_` header row) | row `attrs` / header flags | `<tr style="…">`, all-`<th>` row | implemented (T8) |
| `[alias]url` definition lines | (no node: collected into the alias table) | never renders | implemented (T9) |
| `"text":alias` reference | `.link` (href from the alias table) | `<a href="defined-url">` | implemented (T9) |
| block attributes on `p.` (`{style}`, `(class#id)`, `[lang]`, `< > = <>`, `(`/`)`) | `.paragraph.attrs` | `<p style="…" class="…" id="…" lang="…">` | implemented (T10) |
| block attributes on `hN.` | `.heading.attrs` | `<h2 style="…" lang="…">` | implemented (T10) |
| block attributes on `bq.` | `.block_quote.attrs` (inner `.paragraph` unmarked) | `<blockquote style="…">` | implemented (T10) |
| `bc.` block code | `.code_block` (escaped content, `escape` flag) | `<pre><code>` with `<`/`>` escaped | implemented (T11) |
| `pre.` preformatted text | `.code_block` (verbatim, `escape = false`) | `<pre>` verbatim | implemented (T11) |
| `bq..` extended quote | one `.block_quote` of blank-line-separated `.paragraph`s | `<blockquote><p>…</p><p>…</p></blockquote>` | implemented (T12) |
| `bc..`/`pre..` extended code | `.code_block` with blank lines as content | `<pre><code>` / verbatim `<pre>` | implemented (T12) |
| `[N]` footnote reference | `.footnote_ref` (number) | `<sup class="footnote"><a href="#fnN">N</a></sup>` | implemented (T13) |
| `fnN.` footnote block | `.paragraph` (attrs `class="footnote" id="fnN"`, leading `.superscript`) | `<p class="footnote" id="fnN"><sup>N</sup> body</p>` | implemented (T13) |
| `bq.:URL` citation | `.block_quote` (`cite` URL + attrs) | `<blockquote cite="URL" style="…">` | implemented (T14) |
| character replacements (`"`/`'` → curly, `--`/` - `, `...`, digit-adjacent `x`, `(c)`/`(r)`/`(tm)`, `(1/4)`/`(1/2)`/`(3/4)`, `(o)`, `(+/-)`) | `.text` (arena-owned replaced payload) | `“ ” ‘ ’ — – … × © ® ™ ¼ ½ ¾ ° ±` | implemented (T15) |
| inline `==...==` escaping | `.text` (borrowed literal payload, no replacements) | literal text, HTML-escaped | implemented (T16) |
| block-level `==` escaping (lone `==` lines) | `.html_block` (verbatim payload) | raw passthrough, no `<p>` wrapper | implemented (T16) |
| `|mods|.` line attributes | `.paragraph.attrs` (the §8 set) | `<p style="…" class="…" id="…" lang="…">` | implemented (T17) |
| image alignment (`!<x!`/`!>x!`/`!=x!`/`!-x!`/`!^x!`/`!~x!`) | `.image.attrs` (style fragment) | `<img style="float:left;" …>` | implemented (T18) |
| image `{style}`/`(class#id)`/padding | `.image.attrs` (style/class/id) | `<img style="…" class="…" id="…">` | implemented (T18) |
| image sizing (`10x20`, `10w 20h`, `20%x40%`, `20%`) | `.image` width/height | `width="10" height="20"` | implemented (T18) |
| `++x++` big / `--x--` small | `.big` / `.small` | `<big>` / `<small>` | implemented (T19) |
| span attributes `%{style}(class#id)[lang]x%` | `.span` (attrs payload) | `<span style="…" class="…" id="…" lang="…">` | implemented (T20) |
| `{...}` character macros (`{c|}`…`{:(}`) | `.text` (replaced payload) | `¢ £ ¥ Á ä ¼ • ☺ ☹` | implemented (T20) |
| phrase attributes on every operator (`*{...}x*`, `_(...)x_`, doubled/long) | `.phrase` (attrs payload) | `<strong style="…">` etc. | implemented (T21) |
| `??x??` citation | `.cite` | `<cite>` | implemented (T22) |
| `ABC(def)` acronym | `.acronym` (title payload) | `<acronym title="…">ABC</acronym>` | implemented (T22) |
| `dl. term:definition` | `.list` (`.definition` kind) → `.list_item` (term/definition role) | `<dl>`/`<dt>`/`<dd>` | implemented (T23) |
| `clear.` marker | (no node: a pending fragment folded into the next block's attrs) | `style="clear:both;"` (or `left`/`right`) | implemented (T24) |
| `notextile.`/`notextile..` | `.html_block` (verbatim payload) | raw passthrough, no `<p>` wrapper | implemented (T25) |

T1/T2/T4 refer to the ledger cards in docs/WORK-LEDGER.md. "T4" is the
phrase/link/image/list milestone this audit drove; every new row is pinned
by a fixture pair plus exact-span unit tests in `src/textile.zig`, and the
convergence test in `tests/fixtures_test.zig` proves the shared renderer
produces byte-identical output for equivalent Markdown/Textile inputs
(Textile `*x*` ↔ Markdown `**x**`, `_x_` ↔ `*x*`, `"x":u` ↔ `[x](u)`,
`!img.png!` ↔ `![](img.png)`, `# x` ↔ `1. x`).

## 2. Gaps vs. Textile 2 semantics: audit results

The audit walked the two references feature by feature. The **biggest
user-visible gaps** were the inline phrase-modifier family, links, images,
and lists — the four families listed in this milestone's brief — because
every paragraph in the documented examples uses at least one of them, and
the previous slice rendered them literally. All four are now implemented.

Remaining gaps are deliberate and recorded in docs/FEATURE-MATRIX.md as
planned/deferred. The image-modifier family — alignment, CSS
class/id/style, padding, and sizing (`10x20`, `10w 20h`, `20%`) — was
the last large documented gap and is now implemented (T18); see §16.
The character-replacement macros — curly quotes, em/en dashes, ellipsis,
`x` dimension sign, `(c)`/`(r)`/`(tm)`, and the fraction/degree/plus-minus
paren forms — are now implemented (T15); see §13. Textile 2's `{...}`
macro table is now implemented too (T20) — the documented cent/pound/yen
and accented-letter forms with their mirrored orders; see §18. The span
phrase-attribute forms (`%{style}(class#id)[lang]x%`) are implemented as
well (T20) — see §18.

Tables were the last large *block* gap; they are now implemented (T8) —
see §6. The largest remaining *inline* gap, link aliases, is now
implemented too (T9) — see §7. Block attributes are implemented (T10) —
see §8 — `bc.`/`pre.` block code is implemented (T11) — see §9 —
`bq..`/`bc..`/`pre..` extended blocks are implemented (T12) — see §10 —
footnotes (`fnN.`/`[N]`) are implemented (T13) — see §11 —
block-quote citations (`bq.:URL`) are implemented (T14) — see §12 —
the character-replacement macros are implemented (T15) — see §13 —
`==` escaping (inline and block) is implemented (T16) — see §14 —
line attributes (`|mods|.`) are implemented (T17) — see §15 — and the
image modifiers (alignment, sizing, style/class/padding) are
implemented (T18) — see §16.
- **`++bigger++` / `--smaller--`** (`<big>`/`<small>`): documented only by
  Textile 2, not Hobix — the last phrase-family gap, now implemented per
  the user's explicit request (T19); see §17. Runs of 3+ for the
  single-length operators stay literal. The span's attribute forms and
  the `{...}` character macros are implemented (T20) — see §18 — the
  same phrase attributes on every operator are implemented (T21) — see
  §19 — and the citation and acronym forms are implemented (T22) — see
  §20.
- **Definition lists** (`dl.`) are implemented (T23) — see §21. **`clear`**
  is implemented (T24) — see §22. **`notextile.`** is implemented (T25) —
  see §23. With it, every signature the audit's references document is
  implemented: the deferral pile is empty.
- **Textile raw HTML** — Textile keeps `<...>` as plain text (no `.raw_html`
  recognition); documented in the model convergence table. The
  `notextile.` block is the documented way to drop real HTML in (see §23).
- **Bracket/brace forcing** (`c[*oo*]l`) — documented by Textile 2 as a way
  to force intraword formatting; not inferred by this slice (same position
  as docs/TEXTILE-INLINE-CODE.md §2 for `@code@`).

## 3. Chosen behaviors where the references are silent or disagree

Each choice is a *choice*, recorded here and in the feature matrix, never an
accident. "Both references" means Hobix + Textile 2; where they differ the
disagreement is named.

1. **Phrase delimiter runs.** `*`/`_` of length 1 are strong/emphasis and of
   length 2 are bold/italic (both references agree: "doubling the
   underscores or asterisks"); `-`/`+` are del/ins at length 1 and
   small/big at length 2 (Textile 2's `--smaller--`/`++bigger++`;
   implemented per the user's request, §17); `^`, `~`, `%` are
   single-length only. Runs longer than any documented operator stay
   **entirely literal** (`***x***` is never split into literal `*` + bold
   `**`), and unmatched openers stay literal — the same conservatism as
   `@code@` edge cases.
2. **Boundary rule.** An opener needs a whitespace-or-punctuation boundary
   before and non-whitespace content immediately after; a closer needs
   non-whitespace before and a whitespace-or-punctuation boundary (or line
   end) after. This is exactly the documented `@code@` contract
   (docs/TEXTILE-INLINE-CODE.md §2) applied uniformly. Textile 2's
   `c*oo*l` counterexample, edge-whitespace phrases, and intraword
   `a^2`/`50%` all stay literal (fixture `phrase-boundaries`).
3. **Nesting and LIFO.** Phrase content is scanned for nested phrases
   (`*_way_*` is Textile 2's own example). Matching is strict LIFO: a
   closer closes only the innermost open phrase with the same character and
   run length. A mismatched closer (e.g. a `*` while an `_` is innermost)
   stays literal and does not close a deeper opener.
4. **Same-line and single-pass.** Phrases, like `@code@`, never cross a line
   ending. The scanner is one linear pass over the line (scan → LIFO match →
   emit with an explicit work stack, so deep nesting cannot overflow the
   call stack); code-span opacity is preserved — a pending `@` opener makes
   the intervening bytes opaque to phrases/links/images, so
   `@*strong* "link":u@` stays one code span.
5. **Link display text is plain text.** Textile 2 documents no formatting
   inside `"text":url`, so the display text is one plain `.text` node (not
   re-scanned), which also makes nested links impossible by construction.
   Image src/alt are likewise opaque.
6. **Link URL boundary.** The URL runs to whitespace or a closing bracket
   (`)` `]` `}`); the bracket trick `You["gotta":url]seethis!` (Textile 2)
   therefore never swallows its `]`. Common trailing sentence punctuation
   (`.`, `,`, `;`, `:`, `!`, `?`, quotes, `)]}`) is excluded from the URL
   (Hobix: "the link won't include any trailing punctuation"). `&` in URLs
   is escaped by the shared renderer like Markdown hrefs (Textile 2's
   "unescaped `&` within URLs will be properly escaped").
7. **Link title.** `"text (title)":url` — the parenthesized suffix of the
   display text, recognized only when preceded by a space (so
   `"a(b)":url` has no title and display `a(b)`). The title is arena-owned
   and HTML-escaped at render, like Markdown titles.
8. **Image alt/title.** `!url(alt)!` (Hobix, no space) and `!url (alt)!`
   (Textile 2, with space) both set the alt; per the Hobix example the alt
   also becomes the title. The shared renderer's fixed attribute order is
   `src`, `alt`, `title` (Hobix's raw output shows `title` before `alt`;
   Oliver's order is the renderer policy of docs/ARCHITECTURE.md).
9. **Lists are single-line, tight, and marker-depth driven.** Each item is
   one line (`*`/`#` run + space/tab + content). Nesting is by marker count,
   not indentation (both references' `**`/`##` examples). Items render
   tight (no `<p>`), like Hobix's `<li>A first item</li>`. A blank line, a
   block signature, or any non-marker line closes the list tree — an
   unmarked line after list content is a fresh paragraph, and a following
   marker line starts a new list (neither reference defines multi-line
   items or lazy continuation).
10. **Depth jumps and marker switches.** `* a` then `*** b` (skipping a
    level) opens the intermediate list with an empty item — deterministic,
    but outside the documented examples. A different marker at the same
    depth closes that list and opens a sibling list (`* a` / `# b` are two
    sibling lists, matching the "each item in its own paragraph" reading).
    A mixed run (`*#`) or a run not followed by space/tab is ordinary text.
11. **List placement.** Marker lines interrupt an open paragraph or `bq.`
    quote (they are recognized block signatures), and the resulting list
    attaches to the same parent the interrupted block would have had — the
    root. Lists inside block quotes are not in either reference and are
    deferred.
12. **Opaque-atom precedence.** Code spans, links, and images are atoms
    discovered in the same scan as phrase delimiters; their contents are
    opaque and they are never split by phrase scanning. Phrase delimiters
    inside link display text or image src/alt are not recognized (they are
    inside atoms).

## 4. Complexity

The inline pass is three linear passes over the line (item scan, LIFO
match, emit) plus a work stack for nested phrase emission — no recursion,
no substring rescans, no quadratic delimiter storms (the 10,000-pair
`*ok*`/near-miss storm and the 2,000-deep nesting test in `src/textile.zig`
run as ordinary unit tests, and each passes under `std.testing.allocator`).
Failing link/image lookaheads only ever scan up to the next `"`/`!` (or a
URL's whitespace), and those segments are disjoint, so the scan is linear
even for hostile quote/bang runs.

Table parsing is likewise linear: each row is scanned once into cells and
a single close-time pass resolves the column defaults, so a 20,000-row
storm test in `src/textile.zig` runs as an ordinary unit test.

## 5. Acceptance contract

The fixture wall added by this audit:

- the full phrase-modifier family with exact node spans and byte-exact HTML
  (`phrase-modifiers`, `phrase-in-heading`);
- documented nesting `*_way_*` plus deeper same-type/other-type nesting
  (`phrase-nesting`);
- every boundary fallback: intraword, edge whitespace, over-long runs,
  unmatched openers, and the big/small + em-dash interplay
  (`phrase-boundaries`, `phrase-big-small`);
- links: trailing punctuation, mailto, relative URLs, titles, the bracket
  trick, and literal fallbacks (`link-basic`, `link-title`,
  `link-bracket-trick`, `link-literal`);
- images: absolute/relative src, Hobix and Textile 2 alt forms, the link
  attachment, and literal fallbacks for deferred modifiers and malformed
  shapes (`image-basic`, `image-linked`, `image-literal`);
- lists: bullet/ordered basics, mixed-depth nesting, sibling lists, and
  termination by blank line, plain text, and signatures
  (`list-basic`, `list-nested`, `list-mixed`);
- cross-family composition and `@code@` opacity (`inline-composition`);
- tables: the Hobix examples byte-for-byte (basic, header cells, the cell-
  attribute rows, colspan, rowspan, cell style, signature on its own line,
  row attributes), the Textile 2 complex example, the header-alignment
  propagation rule, inline content in cells, literal fallbacks, and block
  closing (`table-basic` … `table-close`);
- link aliases: the Hobix example, the Textile 2 definition-block form,
  precedence/case-sensitivity, and literal fallbacks
  (`link-alias-basic`, `link-alias-def-block`, `link-alias-precedence`,
  `link-alias-literal`);
- shared-model convergence with the Markdown frontend (see §1) — including
  `"x":alias` + `[alias]url` ↔ `[x][a]` + `[a]: http://u`, byte-identical.

## 6. Tables (T8): pinned behaviors

Both references document the syntax; only Hobix shows rendered output, so
Hobix's HTML is the byte-level target where it exists, and Textile 2's
prose fills the gaps. Every choice below is a *choice*, recorded here and
in the feature matrix.

**Block shape.** A table is its own block: consecutive row lines compose
one table until a blank line or any other block-level line (a signature, a
heading, a list marker, or plain paragraph text closes it). Two tables
need a blank line between them. An optional `table<mods>.` signature opens
the table — alone on its own line (Hobix) or followed by a space and the
first row (Textile 2's `table(fig). {color:red}_|Top|Row|`). A signature
that never receives a row produces no table at all (tables must be in
their own block). A row must start with `|` (after any row modifiers) and
end with `|`; every `|` splits — Textile documents no pipe escape — so
`|a|b` (no closing pipe) is a paragraph. Rows need not be aligned: each
row emits exactly its cells (the rowspan example's `| b |` is a one-cell
row). Row-shaped lines can open a table even without a signature
(consecutive `|…|` lines are a table), and a modifier-prefixed row is
accepted as the first line too — the references only ever show that shape
inside a table, but it is unambiguous.

**Modifiers and the `. ` contract.** Cell modifiers (`_`, `<`, `>`, `=`,
`<>`, `^`, `~`, `\2`, `/2`, `{style}`, `(class#id)`, `[lang]`, `(`/`)`
padding) must be terminated by a period followed by a space (Textile 2:
"a period followed with a space must be placed after any modifiers"). A
terminator without the space — `|_.|`, `|_.< a |` — is not a modifier run:
the whole cell stays verbatim. Row modifiers end at the first `|` (Textile
2's `{color:red}_|Top|Row|`) or after `. ` (Hobix's `{background:#ddd}.
|This|…`). A malformed token anywhere in the run (an unclosed `{`, a
non-modifier character) makes the whole line literal.

**Rendering.** Cells render as flat `<tr>` rows with no `<thead>`/`<tbody>`
— both references show flat rows even with header cells (the model's
`sections` flag is false for Textile, true for GFM; docs/DOCUMENT-MODEL.md).
`_` marks a header cell (row-level `_` marks the whole row), rendered
`<th>` (Hobix). Cell content is verbatim, including leading/trailing
spaces (`| name |` → `<td> name </td>`), and is inline-parsed (emphasis,
links, images, `@code@` all work inside cells). Attributes emit in the
fixed render order style/class/id/lang; the composed style joins its parts
with `; ` and a trailing `;` in the pinned order user `{style}`,
padding-left, padding-right, text-align, vertical-align (`h2()>.` →
`style="padding-left:1em; padding-right:1em; text-align:right;"`).
Alignment renders as CSS (Hobix's `style="text-align:left;"`), never the
GFM `align` attribute.

**Header-alignment propagation.** Textile 2: "When a cell is identified
as a header cell and an alignment is specified, that becomes the default
alignment for cells below it." Walking the table top-down, a header cell
with an explicit alignment updates its column's default; every cell below
inherits the current default unless it carries its own alignment (the
"override" the references describe). Only horizontal alignment propagates
(`^`/`~` vertical stays per-cell). The resolved defaults are recorded in
`table.alignment`; each cell's resolved alignment is composed into its
`style` at parse time. The first explicit-alignment header cell in a
column wins over later ones (a later header row restarts its column's
default for the cells below it).

**Table-signature alignment.** Textile 2 describes table-level `<`/`>`/`=`
as alignment of the table itself (`<`/`>` float, `=` sets left/right
margins to auto) with no literal HTML in either reference; Oliver pins
`float:left;`, `float:right;`, and `margin-left:auto;margin-right:auto;`
respectively. `<>` is cells-only (Textile 2) and rejected on the
signature.

**Literal fallbacks (all pinned by `table-literal`).** No closing pipe;
modifiers without the `. ` terminator; `table.` followed by non-row text
(`table. of contents` stays a paragraph — the rest after the period must
parse as a row); a modifier run without a `. ` or `|` terminator; an
unclosed `{`/`(`/`[` inside a cell (the line is still a row, the cell
verbatim). `||` is a degenerate one-cell row and stays a table.

## 7. Link aliases (T9): pinned behaviors

Both references document the alias mechanism: Hobix "Link Aliases" (the
`[hobix]https://hobix.com` example, with uses before the definition) and
Textile 2 "Links" ("place one or more links in a block of it's own, it
can be anywhere within your document", then `"Text to display":alias`).
Every choice below is a *choice*, recorded here and in the feature matrix.

**Definition lines.** A definition is a line of the form `[alias]url`:
`[` + a non-empty alias with no `[` + `]` + a non-whitespace URL running
to end of line. Textile 2's "block of its own" is read loosely on purpose:
the Hobix example places the definition directly after the paragraph with
no blank line, so a def line needs no separation. A recognized def line
**vanishes from output without changing the surrounding block** — an open
paragraph or list continues across it ("place the URL anywhere in your
document"), and a bare block of def lines renders nothing. A def line that
lands between table rows closes the table (the table's own rule: any
non-row line ends it).

**Resolution.** A `"text":alias` link whose URL token matches a defined
alias uses the defined URL; the token is otherwise an ordinary URL — an
undefined alias is simply a relative URL (no error), and a defined alias
always wins over the token's literal bytes. Matching is **exact and
case-sensitive** and the **first definition of an alias wins** — the
references are silent on both, so the conservative, deterministic choices
mirror the Markdown §4.7 machinery. The definition's URL is verbatim (no
trailing-punctuation trimming, unlike reference URLs).

**Scope.** Aliases resolve in every inline context — paragraphs, headings,
list items, and table cells — because the alias table is document-global
and collected before any inline parsing. Image link attachments
(`!url!:href`) stay direct-URL only; neither reference documents aliases
there. Titles work unchanged: `"text (title)":alias`.

**Literal fallbacks (all pinned by `link-alias-literal`).** `[1] See
footnote` (space after `]`), `[]http://x` (empty alias), `[x]` (no URL),
`[x] url with space` (whitespace in the URL), and a def-shaped substring
inside a line are all ordinary paragraph text.

## 8. Block attributes

Both references document the full block attribute set — Hobix "Attributes:
Block Attributes / Block Alignments" and Textile 2 "Block Attributes" —
and they agree: modifiers sit **between the marker and its period** for
`p`, `hN`, and `bq` signatures, and the period must be followed by a space
(or tab, Oliver's consistent extension). `h2()>. Bingo.` is the Hobix
example verbatim. Every choice below is pinned by the `block-attr-*`
fixtures and the unit tests in `src/textile.zig`.

**The token set** is the table family's (shared `scanMods`): `{style}`,
`(class)`, `(#id)`, `(class#id)`, `[lang]`, `<`/`>`/`=`/`<>` alignment,
and `(`/`)` padding — but **not** the table-only `_`, `^`, `~`, `\n`
colspan, or `/n` rowspan (those stay literal on a block signature).
Tokens are order-independent; the composed style always renders in the
pinned order user-style → padding-left → padding-right → text-align
(`{color:blue;margin:30px}` → `style="color:blue; margin:30px;"`).

**Alignment** on a block is `text-align` (Hobix: `p<.` → `<p
style="text-align:left;">`), unlike the table signature's float/centered
form. `<>` renders `text-align:justify` — it is valid on blocks, even
though the table machinery reserves it for cells.

**Padding.** A bare `(` directly before the period (or another `(`/`)`,
or end of line) is one em of left padding and needs **no closing paren**:
`p(.` = `padding-left:1em;`, `p((.` = 2em, `p))).` = `padding-right:3em;`
(Hobix). A `(` followed by other bytes opens a `(class#id)` spec that must
close with `)`, or the whole line stays literal. An empty class is
omitted: `p(#big-red).` renders `<p id="big-red">`, not `class=""`.

**`bq` placement.** A `bq` signature's attributes land on the
`<blockquote>` element and the single inner paragraph is unmarked (the
same structure `closeBlock` already used for plain quotes).

**Literal fallbacks (pinned by `block-attr-literal`).** An unterminated
`(class` — `p(foo not closed` — a period not followed by whitespace —
`p>.no-space` — a doubled period — `p.. double` (the extended `bq..`
form exists only for `bq`/`bc`/`pre`, so `p..` is not a marker) — the
`bq:...` citation form — and a non-`hN` marker like `h1x.` are all
ordinary paragraph text with no attributes.

## 9. Block code and preformatted text (T11): pinned behaviors

Hobix documents neither `bc.` nor `pre.` as signatures (its pre/code
example is raw HTML). Textile 2 documents **`bc`** — "block code": "a
preformatted section like the 'pre' block, but it also gets a `<code>`
tag", and "within a `bc` block, `<` and `>` are translated into HTML
entities automatically" — and the current Textile docs document both
**`bc.`** ("a block of lines of code") and **`pre.`** ("pre-formatted
text"). Oliver implements both per the two-reference majority; every
choice below is pinned by the `code-block-*` fixtures and the unit tests
in `src/textile.zig`.

**Ownership.** A single-period `bc.`/`pre.` signature opens a leaf that
owns every following non-blank line, **verbatim** — signature-shaped
lines (`p. still code`), list markers, and table rows stay code content.
The block ends at the **first blank line** (Textile 2: "Normally, a block
ends with the first blank line encountered") or at EOF; it interrupts an
open paragraph and closes open lists and tables. The first line's leading
whitespace is consumed as the marker's separator (the shared rule); every
continuation line keeps its leading whitespace byte-for-byte.

**Rendering.** `bc` publishes the shared `.code_block` payload with the
default escaping, so `<`/`>` (and `&`, `"`) are escaped inside
`<pre><code>` — byte-identical to a Markdown fenced block of the same
content (proven by the convergence pair). `pre` sets the verbatim
`escape = false` form: content is written inside `<pre>` with **no
escaping** and no `<code>` wrapper, so embedded HTML is preserved.

**Modifiers.** The block-attribute set of §8 works on both signatures
(`bc{color:red}.`, `pre(fig#demo)[en].`); the composed attrs land on the
`<pre>` element.

**Literal fallbacks (pinned by `code-block-literal`).** An empty
signature (`bc. `, `pre.` — empty behavior is unspecified, the same rule
`bq.` uses), a near miss (`bcd.`), a bare marker (`bc`), and a plain word
that merely starts with the letters (`prelude.`) are all ordinary
paragraph text.

**Deferred.** The extended **`bc..`/`pre..`** double-period forms (blank
lines inside the block, terminated by the next signature) use the
separately documented extended-block mechanism of §10 and are now
implemented (T12).

## 10. Extended blocks (T12): pinned behaviors

Textile 2 "Extended Blocks" and the current Textile docs agree: two
periods in a signature keep it active across blank lines, running
"until the next signature is found" (current docs: terminated by any
other text block signature, usually `p.`). Oliver implements the three
forms the references discuss — `bq..`, `bc..`, `pre..` — with optional
block modifiers before the double period (`bq{color:red}..`). Every
choice below is pinned by the `extended-*` fixtures and the unit tests
in `src/textile.zig`.

**`bq..`** opens one `<blockquote>` whose inner paragraphs are the
blank-line-separated chunks; unmarked lines continue the current
paragraph with Textile hard breaks (the Textile 2 example — two lines,
no blank — is one paragraph). The quote's attrs come from the
signature's modifiers; inner paragraphs are unmarked, like a plain `bq.`.

**`bc..`/`pre..`** keep every line, **blank lines included**, as verbatim
content (the extended form exists precisely for "code blocks where your
code may have many blank lines scattered through it"); `bc..` escapes
inside `<pre><code>`, `pre..` is verbatim `<pre>`.

**Termination.** A recognized block signature ends an extended block and
opens its own block: a `table<mods>.` signature, an extended or
single-period `bq.`/`bc.`/`pre.` signature, an `hN.` heading, or a `p.`
marker. **List markers, table rows, and plain lines are not block
signatures and remain content** inside an extended block — the literal
reading of "until the next signature is found". Def lines still vanish
inside a `bq..` (the T9 rule applies everywhere) and remain verbatim
content inside `bc..`/`pre..`. A block ends at EOF with its content.

**Literal fallbacks (pinned by `extended-literal`).** Empty extended
signatures (`bq..`, `bc.. ` — behavior unspecified, same rule as the
single-period forms), `p..`/`h1..` (not extended signatures — Oliver
implements only the three forms the references discuss), and the
near-miss `bq..x` all stay ordinary text. A single-period `bq.` still
ends at the first blank line.

## 11. Footnotes (T13): pinned behaviors

Both references describe the same mechanism — Hobix "Footnotes" and
Textile 2 "Footnotes". A `[N]` marker inline becomes a superscript link
to the footnote, and an `fnN.` paragraph provides its content. Oliver
renders the **Textile 2 form** (the newer, classed rendering):

- `[N]` → `<sup class="footnote"><a href="#fnN">N</a></sup>`, where `N`
  is the digit run inside the brackets (any number of digits; `[12]` is
  valid, and numbers beyond `u16` stay literal).
- `fnN. body` → `<p class="footnote" id="fnN"><sup>N</sup> body</p>` —
  the structural `class="footnote" id="fnN"` plus a leading superscript
  whose span is exactly the marker's `fnN`, then a space text node, then
  the body (Hobix's rendered example shows the same space).

**Modifiers.** The §8 block-attribute set applies between the digits and
`fnN.`'s period (`fn1{color:blue}.`, `fn2>.`). The structural
`class`/`id` always come first and win; user modifiers contribute their
`style` and `lang` after them (the renderer writes attrs in order, so a
user class/id would duplicate the structural pair). Pinned by
`footnote-attr`.

**Block behavior.** A `fnN.` signature is a paragraph signature: it
interrupts an open block, and it terminates an open extended block
(§10). Empty signatures (`fn1. `, `fn1{color:red}. ` — no content) stay
literal, like the other block signatures.

**Literal fallbacks (pinned by `footnote-literal`).** Non-digit
brackets (`[x]`, `[abc]`), a digit run not closed by `]` (`[1x]`), a
marker without a digit run (`fn.`), a non-digit marker (`fnx.`), and
empty signatures all stay ordinary text. `[N]` is recognized in any
inline position, including inside a footnote block itself.

## 12. Block-quote citations (T14): pinned behaviors

The current Textile Markup Language Documentation documents the
citation form on its "Block quotations" page — "Block quotes may
include a citation URL immediately following the period" — with the
example `bq.:http://textpattern.com/ A cited quotation.` Learn X in
Y Minutes states the same syntax. Neither Hobix nor Textile 2 mentions
it; the syntax is documented, so Oliver implements it, rendering the
URL as the blockquote's `cite` attribute.

**Rendering.** `bq.:URL body` renders
`<blockquote cite="URL"><p>body</p></blockquote>` with the inner
paragraph unmarked, like a plain `bq.`. The cite attribute follows
the link href policy: non-ASCII bytes are percent-encoded and the
result HTML-escaped at render (the renderer's `writeEscapedHref`),
and sentence punctuation at the end of the URL run is trimmed exactly
like an inline link destination (`bq.:http://x.example.com. Cited.`
→ `cite="http://x.example.com"`; the separator check runs on the
raw run, so the trimmed period cannot double as the required
whitespace). The URL is arena-duped like the link href.

**Modifiers.** The §8 block-attribute set combines with the citation:
the modifiers sit between the signature and the period, the citation
follows it (`bq{color:red}.:URL`, `bq(fig#demo).:URL`). The cite
attribute is emitted first, then the composed attrs in the fixed
render order (cite/class/id/style/lang ordering is pinned by
`bq-cite-mods`).

**Block behavior.** A citation signature is a block signature like any
other: it interrupts an open block and terminates an open extended
`bq..` quote (pinned by `bq-cite-extended`).

**Literal fallbacks (pinned by `bq-cite-literal`).** `bq.:` with no
URL, a space between the colon and the URL, a URL with no whitespace
separator, empty content, and the undocumented `bq..:URL`
extended-citation combination all stay ordinary text. A space after
the period (`bq{color:red}. :URL body`) is not a citation — the
content simply begins with a colon.

## 13. Character replacements (T15): pinned behaviors

All three references document the replacements: Hobix "Entities"
(curly single/double quotes, `--` → em dash, ` - ` → en dash, `...` →
ellipsis, `x` → dimension sign, `(TM)`/`(R)`/`(C)`), Textile 2
"Character Replacements" (`(c)`/`(r)`/`(tm)`, em-dash), and the
current docs "Automatic conversions" (quotes, dashes, ellipsis,
dimension sign, `(tm)`/`(R)`/`(C)`, `(1/4)`/`(1/2)`/`(3/4)`, `(o)`,
`(+/-)`). Oliver implements the intersection-plus-majority — every
paren form documented by an example — and pins each rule below. The
replacements are applied to **plain text only**, at the inline-pass
text emission, so phrase content and link display text get them
(Hobix's own alias example renders `it's` inside a link as a curly
apostrophe) while verbatim payloads do not.

**The rules.**

- **Curly quotes.** `"` is opening `“` when the preceding source byte
  is start-of-content, whitespace, or `([{`; otherwise closing `”`.
  `'` is `’` between letters (apostrophe: `it's`, `I'm`), `‘` when
  preceded by start/whitespace and followed by a letter (`'tis`), and
  `’` otherwise (`dogs'`). The quote direction rule is local and
  stateless (classic Textile behaves the same — `*em*"x"` renders a
  closing `”` after the `*`), pinned by the fixtures.
- **Em dash.** Two consecutive hyphens `--` become `—`; runs longer
  than two are replaced left-to-right (`---` → `—` + `-`, `----` →
  `——`). The em-dash rule operates on plain text: a `--` that forms a
  matched phrase pair is consumed by the phrase scanner first (Textile
  2's `--smaller--` → `<small>`, §17), so only `--` that cannot form a
  pair — space-adjacent, intraword, numeric, or unmatched — reaches
  this rule.
- **Brace macros.** Textile 2's `{...}` character-macro table (§18):
  the documented forms and their mirrored orders map to a single
  character, and every other `{...}` shape stays literal.
- **En dash.** A hyphen with a space/tab on **both** sides (` - `)
  becomes `–`. A hyphen touching letters (`well-formed`, `foo-bar`)
  or at the content edge is untouched.
- **Ellipsis.** Three consecutive periods `...` become `…`;
  left-to-right, so `....` → `…` + `.`.
- **Dimension sign.** A lowercase `x` with a digit on each side,
  allowing at most one space on either side, becomes `×` (`2 x 2` →
  `2 × 2`, `2x4` → `2×4`). Plain `x` in words is untouched.
- **Parenthesized macros.** `(c)`, `(r)`, `(tm)` — case-insensitive
  (Hobix's uppercase forms are documented examples) — become ©, ®,
  ™; `(1/4)`, `(1/2)`, `(3/4)` become ¼, ½, ¾; `(o)` becomes °;
  `(+/-)` becomes ±. Any other parenthesized shape (`(1/3)`, `(cd)`,
  `(c` unterminated) is literal.

**Exemptions.** HTML-looking `<...>` regions (a `<` followed by a
letter or `/`, through the closing `>`) are copied verbatim — a
`title="x"` attribute keeps its straight quotes — and verbatim
payloads never pass through the pass: `@code@` spans, `bc.`/`pre.`
code blocks, and link/image src/alt/title (pinned by
`char-replace-context`). The renderer still escapes the tag bytes as
text (`<b>` → `&lt;b&gt;`, the pre-existing, pinned Textile escaping
behavior), so the exemption is about replacements, not escaping.

**Model.** Replaced text is an arena-owned payload (borrow-or-copy,
the same contract as the Markdown entity resolver); untouched text
still borrows the source. `hasCharMacroTrigger` is the cheap fast
path — text with none of the trigger bytes (`"`, `'`, `-`, `.`, `(`,
`<`, or a digit-adjacent `x`) never allocates.

**Deferred.** Textile 2's `{...}` character-macro table (cent, pound,
yen, ...) is not documented by Hobix or the current docs and stays
literal. The `==` escaping mechanism is implemented (T16) — see §14.

## 14. `==` escaping (T16): pinned behaviors

Textile 2 "Escaping" documents both forms: a lone `==` line opens a
block-escape region whose content is "not formatted by Textile at all"
(for "put[ting] some regular HTML markup in your document"), and an
inline `==...==` "temporarily disabl[es] the inline formatting
functions" — `p. This is ==*a test*== of escaping.` renders the phrase
delimiters literally. The current docs' special-characters page pins the
inline form as the way to suspend the character conversions too:
`Straight quotation marks are =="left alone"== in this example.`
Hobix does not document `==` at all (its only escape is raw HTML); the
other two references agree on the shape, so Oliver implements the
majority (see docs/CLEANROOM.md session 11).

**Block form.** A line whose text is exactly `==`, optionally followed
by trailing spaces/tabs, toggles the region: every line until the next
lone `==` line — blank lines included — is collected verbatim and
published as a raw `.html_block` (the same leaf Markdown §4.6 uses,
rendered with no escaping and no `<p>` wrapper). The content lines are
contiguous in the source, so the arena-owned payload is one exact
source slice. An unterminated region closes at end of input and still
renders its content; an empty region (`==` immediately followed by
`==`) renders nothing. `===` and an indented `==` are not delimiters —
they stay content.

**The delimiter interrupts.** The lone-`==` check runs before every
other block rule, so the escape can be dropped in anywhere: it closes
an open paragraph, the list tree, an open table, and single-period or
extended `bc.`/`pre.`/`bq..` blocks alike (a block signature would do
the same). This is a choice — Textile 2's extended blocks run "until
the next signature is found" and `==` is not a signature — pinned by
the `escape-block-*` fixtures.

**Inline form.** `==` opens at line start or after a Unicode
whitespace/punctuation boundary, must be exactly two equals (a `=` run
of three or more cannot open, and the byte before must not be `=`),
and the content must be non-empty. The content runs to the *first
following* `==`; if that `==` is not itself at an inline boundary
(whitespace, punctuation, or line end), the whole construct stays
literal — the same first-following rule `@code@` uses, so `==x==y` is
plain text. An unmatched `==` is plain text. The delimited span emits
as a `.text` node with the raw borrowed payload: no phrase
formatting, no links/images/footnotes, and no character replacements
(so `2x4`, `--`, and `(tm)` inside stay literal — the current docs'
example is exactly this).

**Rendering and model notes.** The escaped node is still a `.text`
node, so it renders through the shared text path: HTML-escaped
(`"` → `&quot;`), and entity references decode like any text (`&amp;`
renders as `&amp;` — the renderer's entity decoding is a text policy,
not a Textile replacement, and applies uniformly). The node's span is
the inner content only; the `==` delimiters occupy the gap to its
neighbors, so consecutive text children never have contiguous spans
(model invariant 11) and the literal payload is never re-derived by
the merge rule. Inside `@code@`, link display text, and image
src/alt/title the `==` bytes are opaque. The escaped span cannot be
re-entered: content is scanned for the closer in one pass, so nested
escapes do not occur.

## 15. Line attributes (T17): pinned behaviors

The line-attribute form is a pipe-delimited variant of the §8 block
attributes: a line beginning with a pipe, a modifier run, a closing
pipe, a period, and separator whitespace applies the modifier set to
the paragraph. `|{color:red}(note#one)>[fr]|. Styled` renders
`<p style="color:red; text-align:right;" class="note" id="one"
lang="fr">Styled</p>` — byte-identical to `p{color:red}(note#one)>[fr].
Styled` (the unit tests assert the attribute lists are equal element for
element).

**Provenance (recorded in docs/CLEANROOM.md session 12).** The `|...|.`
pipe form is **not** present in the three clean-room references. Textile
2's only pipe-delimited block parameter is the **`|filter|`** filter
form ("A filter may be invoked to further format the text for this
signature"), and neither Hobix, the current Textile docs, nor the
supplementary user-facing sources checked (the original textism
reference, the RedCloth reference manual, learnxinyminutes, the
php-textile docs) document a pipe-attribute paragraph form. Oliver
implements the construct per the user's specification, built entirely
on the documented §8 modifier set — so the *modifiers* and their
composition are reference-backed; only the pipe wrapping is per-spec.

**The grammar.** The modifier run between the pipes is scanned with the
exact §8 token set (`{style}`, `(class#id)`, `[lang]`, `(`/`)`
padding, `<`/`>`/`=`/`<>` alignment) and terminates at the closing
pipe; the period must follow immediately and be followed by a
space/tab, and the content must be non-empty. The composed attribute
list is the same fixed render-order list (style, class, id, lang) the
`p<mods>.` marker produces, landing on `.paragraph.attrs` — the shared
model and renderer are untouched. Row/cell-only tokens (`^`, `~`, `_`,
`\` colspan, `/` rowspan) are rejected.

**Block behavior.** The line-attribute line is a paragraph signature:
like `p<mods>.` it interrupts an open paragraph, closes the list tree,
and terminates an open extended `bq..`/`bc..`/`pre..` block, and its
paragraph continues through unmarked lines (hard breaks) until a blank
line. It is never a table row — rows must end with `|`, and the
attribute form ends with content — so `|{color:red}|. x` after a row
closes the table and starts a styled paragraph.

**Literal fallbacks (pinned by `line-attr-literal`).** No closing pipe
(`|{color:red}|x`), a dot-terminated run (`|{color:red}. text`), a
period not followed by space (`|x|.y`), an empty modifier run (`||. x`),
an empty content (`|x|. `), a malformed modifier (`|{bad`), and any
row/cell-only token (`|^|. x`) all keep the whole line ordinary text.

## 16. Image modifiers (T18): pinned behaviors

The image modifier family is the last large documented Textile gap.
Textile 2 "Images" documents the alignment operators (`!<x!`, `!>x!`,
`!=x!`, `!-x!`, `!^x!`, `!~x!`), the size forms (`10x20` "10 pixels wide
and 20 pixels high", `10w 20h` "the words form", `20%x40%` percentages,
and a single `20%` for proportional sizing), and the block-attribute
`{style}`/`(class)` set; the current Textile docs' "Images" page adds
`=` centering and the `(class)` form. Oliver implements the full family
— Textile 2 plus the current docs — reusing the §8 modifier machinery;
every choice below is pinned by the `image-mods-*` fixtures and the
unit tests in `src/textile.zig`.

**Placement.** The modifier run sits between the opening `!` and the
src (`!>obake.gif!` is the Hobix-shaped form; `!{color:red}>(pic).png!`
and `!()>x.png!` are the current-docs shape). The src must be non-empty
and whitespace-free; after the src comes either the parenthesized alt
(the pre-existing `!url(alt)!` / `!url (alt)!` form, which doubles as
the title) or a size token — **size and alt never combine**, and any
other post-src token makes the whole construct literal.

**Alignment** composes a CSS fragment into the image's style, in the
pinned mapping: `<` → `float:left`, `>` → `float:right`, `=` →
`display:block;margin-left:auto;margin-right:auto` (the current docs'
centered form), `-` → `vertical-align:middle`, `^` →
`vertical-align:top`, `~` → `vertical-align:bottom`. Repeated alignment
modifiers: the **last wins**, the same rule the block-modifier scanner
uses (`!< >x!` is right-aligned).

**Style/class/id/padding** reuse the §8 token grammar: `{style}`, `(class)`,
`(#id)`, `(class#id)`, and `(`/`)` padding (a `(` directly before
`(`/`)` is one em of left padding, `)` one em of right). The composed
style follows the pinned order — user `{style}`, padding-left,
padding-right, alignment fragment — and the style/class/id land on the
image's `attrs` in the fixed render order. The modifiers combine with
the link attachment: `!>pic.png!:href` is a floated linked image.

**Sizing.** The size token parses four documented forms: `10x20` (digits
both sides), `20%x40%` (each side digits or digits-percent), `10w 20h`
(digits only, whitespace-separated, `w`/`h` suffixes consumed), and a
single proportional `20%` (sets both width and height). The digits are
emitted as the `width`/`height` attributes in the shared renderer's
fixed order (`src`, `alt`, `title`, `width`, `height`, attrs).

**Model and renderer.** The shared `.image` payload gained optional
`width`/`height` strings and an `attrs` list, all defaulted — Markdown
images never set them, so the Markdown frontend and the shared renderer
are byte-identical (gate 652/652 untouched), and the Textile attribute
list renders through the same `writeAttrs` path as blocks and cells.

**Literal fallbacks (pinned by `image-literal`).** A malformed modifier
(an unclosed `{` or `(`, a `(`-spec with no `)`), a junk post-src token,
an empty src, an unclosed `!`, and every malformed size shape — a bare
`N`, `x20`, `10x`, a `10w20h` run without the separating space, extra
tokens — keep the whole construct ordinary text. The pre-existing pin
that all modifier shapes stay literal was updated: `!>obake.gif!` now
renders Hobix's own aligned form.

## 17. Big and small phrases (T19): pinned behaviors

Textile 2 "Inline Formatting" documents the pair — "`++bigger++`
Translates into `<big>bigger</big>`" and "`--smaller--` Translates
into: `<small>smaller</small>`" — the only clean-room reference that
carries them (Hobix and the current Textile docs do not). The deferral
(docs/FEATURE-MATRIX.md, recorded ambiguity #18) followed the
"implement once from the majority" rule; the user's explicit request
lifts it, and the implementation slots into the existing phrase
machinery unchanged — a doubled run of `-`/`+` is a phrase operator
like `**`/`__`, with the same boundary contract, strict-LIFO matching,
nesting, and literal-run fallbacks (docs/TEXTILE-PARITY.md §3).

**The operators.** `++x++` → `<big>x</big>` and `--x--` →
`<small>x</small>`, recognized when both delimiters sit at the inline
boundaries (opener: boundary before, non-whitespace content after;
closer: non-whitespace before, boundary after). They nest like the
rest of the family (`++*big*++` → `<big><strong>big</strong></big>`),
and the single-length `-x-`/`+x+` del/ins forms are unchanged.

**The em-dash interplay.** The doubled hyphen run is shared between
`--` the small operator and `--` the em-dash replacement (all three
references document the em dash). The phrase scanner runs first: a
`--` that forms a matched pair is **consumed as a delimiter**, so
`--smaller--` renders `<small>smaller</small>`, never `—smaller—`.
A `--` that cannot form a pair stays text and the em-dash rule applies
unchanged: space-adjacent (`a -- b` → `a — b`), intraword
(`foo--bar` → `foo—bar`), numeric (`2--4` → `2—4`), and unmatched
(`--x` → `—x`, `x--` → `x—`) shapes. Literal `---`/`+++` runs of
three or more stay entirely literal text (the whole run is skipped,
never reseeding a shorter operator) and still em-dash
(`---x---` → `—-x—-`).

**Model and renderer.** The shared `Tag` union gains `.big`/`.small`,
rendered `<big>`/`</big>`/`<small>`/`</small>` through the same enter/
exit machinery as the other phrase tags. Markdown never produces these
tags, so the Markdown frontend is untouched (gate 652/652).

**Literal fallbacks (pinned by `phrase-big-small`).** Runs of 3+
(`+++x+++`, `---x---`), unmatched openers/closers (`--x`, `x--`),
intraword runs (`foo--bar`), edge whitespace (`a -- b`), and opacity
inside `@code@` (where the dashes stay literal) all follow the family
rules. The `phrase-boundaries` fixture's deferred-`--` line became an
over-long-run case (`---smaller---` stays literal).

## 18. Span attributes and the `{...}` character macros (T20): pinned behaviors

Two milestones landed together: the span's phrase-attribute forms and
Textile 2's default `{...}` character-macro table. Hobix "Phrase
Attributes" documents the former — "all block attributes can be applied
to phrases as well by placing them just inside the opening modifier",
with the examples `*{color:red}blushed*`, `_(big)sprouted_`, and
`%[es]cabeza%` — and Textile 2 "Inline Formatting" adds "inline
formatting operators accept the following modifiers: `{style rule}`, `[ll]`,
`(class) or (#id) or (class#id)`". Textile 2 "Character Replacements"
documents the macro table — "there are a whole set of character macros
that are defined by default. All macros are enclosed in curly braces".

**Span attributes.** `%{style}(class#id)[lang]x%` composes the run
through the block-attribute machinery into the `.span` attrs in the
fixed render order (`<span style="…" class="…" id="…" lang="…">`); a
plain `%x%` span carries an empty attr list and is unchanged. The
modifier set is Textile 2's documented inline set — style, class/id,
lang — **not** the block padding/alignment tokens (a `(`/`[`/`{` that
isn't a valid spec ends the run and starts the content). The run must
be followed by non-whitespace content; a malformed run (an unclosed or
empty spec) makes the `%` a non-opener, so the whole construct stays
literal — the same conservatism as a malformed block modifier. The
scan treats the run as opaque (a `%` inside a style value like
`%{width:50%}x%` cannot close the span), and a run with no content
after it (`%(x)%`, `%{color:red}%`) falls back to a **plain span**
whose content includes the run bytes. The same machinery extends to
every other operator's attribute forms (`*{color:red}x*`, `_(big)x_`,
…), composing onto the phrase's own HTML tag (§19).

**The macro table.** The documented forms — each with its mirrored
order where Textile 2 shows one — map to a single character:
`{c|}`/`{|c}` → ¢, `{L-}`/`{-L}` → £, `{Y=}`/`{=Y}` → ¥, `{A'}`/`{'A}`
→ Á, `{a"}`/`{"a}` → ä, `{1/4}` → ¼, `{*}` → •, `{:)}` → ☺, `{:(}` →
☹. The replacements apply to plain text like the rest of the pass:
inside phrase content and link display text, never inside `@code@`,
code blocks, link/image src/alt/title, or `==` escapes.

**The brace-edge rule.** Phrase operators directly adjacent to a brace
(the byte before is `{` or the byte after is `}`) are **not recognized**
— `{*}` and `{-L}` are macros, and brace content is never phrase
content — so the whole `{...}` region stays one text run and reaches
the macro pass intact. Undocumented brace-adjacent shapes (`{*x*}`, a
closer before `}`) therefore render literally.

**Deferred.** The general letter+accent pattern Textile 2 hints at
("many of these macros can be guessed") is **not** generalized: only the
documented forms above are implemented — `{a'}` (lowercase acute),
`{E'}`, and `{C|}` stay literal text (with the standard replacements,
so `{a'}` renders `{a'}` → `{a’}`). The full table is the reference
implementations' data, outside the clean-room rule. Image `[lang]`
remains a recorded deferral.

## 19. Phrase attributes on every operator (T21): pinned behaviors

Hobix "Phrase Attributes" extends the span milestone to the whole
family: "all block attributes can be applied to phrases as well by
placing them just inside the opening modifier", with the examples
`*{color:red}blushed*` → `<strong style="color:red;">blushed</strong>`,
`_(big)sprouted_` → `<em class="big">sprouted</em>`, and
`%[es]cabeza%` → `<span lang="es">cabeza</span>`. Any opener — single,
doubled (`**{...}x**` → `<b style="…">x</b>`, `--{...}x--` → `<small
style="…">x</small>`), or the long operators (`^[fr]x^` → `<sup
lang="fr">x</sup>`, `~[de]x~`) — accepts the same
`{style}(class#id)[lang]` run through the exact span machinery,
composing onto the phrase's **own** HTML tag via the shared `.phrase`
payload (Markdown phrase nodes keep `.none` and render without attrs).

**The same fallback contract as the span forms, pinned by
`phrase-attr-literal`.** A malformed run (an unclosed or empty spec)
makes the operator a non-opener — the whole construct stays literal. A
run followed by whitespace or empty content is not an opener. A run
with no content after it (`*{color:red}*`) falls back to a **plain
phrase** whose content includes the run bytes. An operator character
inside a style value (`*{width:50%}x*`) cannot close the phrase — the
run is opaque to the scan.

**Interaction with the `{...}` macros.** A `{` directly after an opener
is a style token, so `*{c|}bold*` renders `<strong
style="c|;">bold</strong>` — the macro table only sees `{...}` regions
not attached to a phrase opener (the `char-macro-literal` fixture's
line 4 was updated to keep a genuine survival case: `x{*}y` and
`* {c|} bold` still macro). The brace-edge rule (§18) is unchanged:
`{*}` and `{-L}` stay whole.

**Em-dash interplay.** The `--` small operator consumes a paired run as
a delimiter, so `--{color:red}small--` → `<small
style="color:red;">small</small>`; a `--` that cannot form a pair still
em-dashes through the replacement pass (§17 unchanged).

## 20. Citation and acronyms (T22): pinned behaviors

Two Hobix-only inlines landed together — the audit's last two inline
deferrals. Hobix "Footnote-like citation": "Use double question marks
to indicate citation" (`??Cat's Cradle?? by Vonnegut` → `<cite>Cat’s
Cradle</cite>`), and Hobix "Acronyms": "Definitions for acronyms can
be provided by following an acronym with its definition in parens"
(`We use CSS(Cascading Style Sheets).` → `<acronym
title="Cascading Style Sheets">CSS</acronym>`). Neither appears in
Textile 2 or the current docs — the FEATURE-MATRIX "Hobix only"
reading holds, recorded in CLEANROOM session 17.

**Citation.** A doubled `?` run is a phrase operator like `*`/`_`: it
accepts the phrase-attribute run (`??{color:red}x??` → `<cite
style="color:red;">x</cite>`), nests the other operators
(`??*b*??` → `<cite><strong>b</strong></cite>`), and follows the
family's boundary contract. A lone `?` (`Really??` — a question mark
is never an operator) and runs of 3+ (`???x???`) stay literal, and the
mods-run fallbacks from §18/§19 apply unchanged (malformed run
literal, whitespace-after not an opener, `??{color:red}??` falls back
to a plain cite whose content includes the run bytes).

**The both-flag delimiter fix.** This milestone surfaced a latent
matcher gap: a delimiter whose byte-before *and* byte-after both
guard a boundary (e.g. `_` between `?` and `(` in `??_(big)x_??` —
punctuation before, a mods-run `(` after) is both an opener and a
closer. The matcher previously treated it as a closer only, dropping
it when the stack top did not match — the phrase never opened. The fix
is the standard delimiter-stack rule: try closing against the stack
first, and only when the top does not match does the run act as a
fresh opener. This also lets mod-bearing phrases open after
punctuation generally (`(_(big)x_)` → `(<em class="big">x</em>)`).

**Acronyms.** A run of 2+ uppercase ASCII letters at an inline boundary
directly followed by a non-empty parenthesized definition;
`US(United States)` → `<acronym title="United States">US</acronym>`,
and punctuation like the surrounding parens still guards the
boundary (`(CSS(Style Sheets))`). The definition closes at the first
`)` (the same conservatism as the link paren-title rule) and is the
`title` — opaque: no phrase formatting and no character replacements.
The conservative shape contract stays literal, all pinned by
`acronym-literal`: a single letter (`I(think)` never becomes an
acronym), an intraword run (`xCSS(no)`), an empty (`CSS()`) or
unclosed (`CSS(open`) definition, and a run containing non-letters
(`HTML5(Standard)` stays literal text). `@code@`, code blocks, link
display text, and `==` escapes stay opaque. The acronym's uppercase
run is skipped whole when it cannot form an acronym, keeping the
single-pass scan linear.

## 21. Definition lists (T23): pinned behaviors

The audit's last block-level deferral, from Textile 2 "Definition
lists": `dl. term:definition` lines compose a definition list.

> dl. textile:a cloth, especially one manufactured by weaving\
> or knitting; a fabric\
> format:the arrangement of data for storage or display.\
> Note that there is no space between the term and definition. The\
> term must be at the start of the line (or following the "dl"\
> signature as shown above).

**The model convergence.** The definition list rides the shared `.list`
machinery as a new `.definition` kind: the `.list` node renders
`<dl>`, and its `.list_item` children carry a term/definition role in
a new `data.list_item` payload that renders `<dt>`/`<dd>` (plain
list items keep `.none` and render `<li>` unchanged — Markdown
untouched). `dl<mods>.` block attributes land on the `<dl>` element.
The list is tight, so the term and definition paragraphs render
inline without `<p>` wrappers.

**The term contract.** A term is a non-empty run of non-whitespace,
non-colon bytes at the line start (or right after the signature),
immediately followed by `:`; the definition is the rest of the line
(leading whitespace after the colon is skipped — the lenient reading
of "no space between the term and definition", which is enforced on
*both* sides of the colon: `term : def` is not a pair). The definition
must be non-empty; a definition may span multiple lines — any line
without a `term:` prefix continues the open definition, with Textile
hard breaks between lines. A colon inside a definition is fine
(`url:http://example.com` — the pair splits on the term's first
colon), and the term's own inlines are parsed (`*term*:def` →
`<dt><strong>term</strong></dt>`).

**The term-run rule.** Because the term cannot contain whitespace, a
line like `see also: not a new term` is **not** a new pair — `see`
stops at the space — so it continues the open definition. Pinned by
`dl-literal`.

**Termination.** The list closes at a blank line, a recognized block
signature (including a fresh `dl.`, which starts a new list), a
`[alias]url` def line, or end of input. Inside the list, an empty
`dl.`/`term:`-less signature line stays literal — the same
conservatism as an empty `bq.`: `dl. plain text`, `dl. term:` (empty
definition), and `dl. ` (empty signature) are all ordinary text,
and a failed signature line is a plain paragraph (pinned by
`dl-literal`).

**The current-docs conflict.** The current Textile Markup Language
Documentation documents a **different** definition-list grammar —
`- term := definition` lines with dash markers and multi-line
definitions ending in `=:` (the php-textile form). The two
references do not agree, so this slice implements the requested
Textile 2 form and records the dash-marker form as the documented
remainder (see CLEANROOM session 18).

## 22. The `clear.` marker (Textile 2 "clear")

Textile 2's `clear` block: a lone `clear.` line, optionally with a
`<`/`>` direction, that renders nothing itself — "the next block
should emit a CSS style attribute that clears any floating
elements". Implemented (T24) as a pending fragment the next block to
open folds into its attribute set, so it converges on the §8
block-attribute machinery rather than adding a block kind.

**The marker contract.** The marker must be alone on its line:
`clear.` (clear both), `clear<.` (clear left), or `clear>.` (clear
right), with only trailing whitespace after the period — a bare
`clear.` at end of line counts. Any other shape is ordinary text:
content after the marker (`clear. with content`), a space before
the period (`clear x.`), a word merely starting with `clear`
(`clearb.`), or a different modifier. The marker at end of input
with no following block is dropped silently. Pinned by
`clear-literal`.

**The fold.** The pending fragment becomes the block's first
`style` rule, prepended to any style the block already carries and
followed by the fixed render order (style/class/id/lang): `clear.`
+ `p{color:red}. Both.` → `<p style="clear:both; color:red;">`. It
applies to **every** block family — paragraphs, headings, block
quotes (the `bq.:URL` cite first, then the clear style), lists,
tables, definition lists, footnotes, and code blocks — and to the
plain unmarked paragraph that follows the marker. A `[alias]url`
def line between the marker and the block does not consume it.

**Interaction with open blocks.** The marker is a block signature:
it closes an open extended `bq..`/`bc..`/`pre..` (via §10's
signature rule) and a definition list, and it interrupts the list
tree and any open table — the fragment parks and the next block
carries it. Inside a single-period `bc.`/`pre.` block the marker is
code content like any other non-blank line (the leaf owns every
line until a blank line). Pinned by `clear-basic`.

## 23. The `notextile.` raw block (current Textile docs "No formatting")

The audit's last deferral, implemented (T25): `notextile.` (or the
extended `notextile..`) at the start of a block skips Textile
processing entirely. It is the signature form of the `==` escape —
content passes through as one raw `.html_block` leaf, byte-for-byte
from the source (CRLF preserved), no inline formatting, no character
replacements: `notextile. This line <em>will not</em> be
*Textilised*.` renders `This line <em>will not</em> be
*Textilised*.`, the `<em>` a real tag.

**Provenance.** Only the current Textile Markup Language
Documentation documents the form ("No formatting (override
Textile)": "For blocks of elements add a notextile. or notextile..
at the start of the block"); Textile 2 does not — its Escaping
section presents the `==` mechanism as the way to "just get out of
the way and let you put some regular HTML markup in your document"
(see CLEANROOM session 20). The slice implements the current-docs
form and converges it on the `==` machinery.

**The marker contract.** The marker must be the whole word at the
line start, followed by one period (or two for the extended form)
and then separator whitespace or end of line — a **bare marker** is
allowed, since "for blocks of elements" the content follows on
later lines. Any other shape is ordinary text: a word merely
starting with `notextile` (`notextiles.`), a missing period
(`notextile with no dot`), a non-space directly after the period
(`notextile.extra`), or a mid-paragraph occurrence. Block modifiers
are not documented for the form, so `notextile{...}.` stays literal
(the same conservatism as `==`). A bare marker with nothing after
it (a blank line or end of input) renders nothing. Pinned by
`notextile-literal`.

**The block contract.** The single-period form owns every following
non-blank line, ending at the first blank line — the same rule
`bc.` uses, so signature-shaped lines stay raw content. The
extended form keeps blank lines as content and runs until the next
recognized block signature (like `bc..`); the trailing blank lines
before the signature stay in the payload. Same-line content after
the marker joins the block's first line. Pinned by
`notextile-basic`.

**Interactions.** The marker is a block signature: it closes an
open extended `bq..`/`bc..`/`pre..` and a definition list, and
interrupts the list tree and any open table. Inside a single-period
`bc.`/`pre.` block the marker is code content like any other
non-blank line (the leaf owns everything until a blank line). A
`==` delimiter interrupts an open raw block, as it interrupts every
block (the escape check runs before all other rules). A pending
`clear.` has no attribute list to land on (the `.html_block` leaf
carries none), so the fragment is dropped rather than leaking onto
the next block. An unterminated block at end of input still
renders, like an unterminated `==` region.

## 24. Audit coverage scorecard (final)

The audit's closing scorecard: **every block signature and inline
operator the two references document is implemented**. The deferral
pile that T1 opened is empty; what remains is a short, named list of
reference-documented forms Oliver deliberately does not implement (see
below) plus the recorded reference disagreements in §2/§3.

**Verification method.** Every row below is pinned by at least one
fixture pair in `tests/fixtures_test.zig` (byte-exact input/output) and
most also by exact-span unit tests in `src/textile.zig`; the shared
renderer's Markdown side is gated byte-for-byte against CommonMark
0.31.2 (652/652). The matrix's example strings were re-verified live
against `oliver render --from textile` during this wrap-up.

| family | fixture pairs | status | pinned in |
| --- | --- | --- | --- |
| paragraphs (`p.`, bare lines) | 4 | implemented (T1) | §3 |
| headings `h1.`–`h6.` | 2 | implemented (T1) | §3 |
| block precedence (marker interruption) | 2 | implemented (T1) | §3 |
| line breaks | 1 | implemented (T1) | §3 |
| block quotes `bq.` | 7 | implemented (T1) | §3 |
| block-quote citations `bq.:URL` | 4 | implemented (T14) | §12 |
| inline code `@code@` | 6 | implemented (T2) | TEXTILE-INLINE-CODE |
| special chars / unicode | 2 | implemented (T1/T2) | §3 |
| phrase family (`*`, `_`, `**`, `__`, `-`, `+`, `^`, `~`, `%`) | 4 | implemented (T4) | §3 |
| big/small `++`/`--` | 1 | implemented (T19) | §17 |
| links `"t":u` (+ title, bracket trick) | 4 | implemented (T4) | §3 |
| link aliases `[alias]url` | 4 | implemented (T9) | §7 |
| images `!u!` (+ alt, linked) | 3 | implemented (T4) | §3 |
| image modifiers (align/size/style) | 2 | implemented (T18) | §16 |
| lists `*`/`#` (+ nesting) | 3 | implemented (T4) | §3 |
| definition lists `dl.` | 2 | implemented (T23) | §21 |
| tables `|a|b|` (+ modifiers) | 13 | implemented (T8) | §6 |
| block attributes (§8 set) | 5 | implemented (T10) | §8 |
| line attributes `|mods|.` | 2 | implemented (T17) | §15 |
| block code `bc.` / preformatted `pre.` | 4 | implemented (T11) | §9 |
| extended blocks `bq..`/`bc..`/`pre..` | 4 | implemented (T12) | §10 |
| footnotes `fnN.`/`[N]` | 4 | implemented (T13) | §11 |
| character replacements | 3 | implemented (T15) | §13 |
| `{...}` character macros | 2 | implemented (T20) | §18 |
| span attributes `%{...}x%` | 2 | implemented (T20) | §18 |
| phrase attributes on every operator | 2 | implemented (T21) | §19 |
| citation `??x??` / acronyms `ABC(def)` | 4 | implemented (T22) | §20 |
| `==` escaping (inline + block) | 4 | implemented (T16) | §14 |
| `clear.` marker | 2 | implemented (T24) | §22 |
| `notextile.` raw block | 2 | implemented (T25) | §23 |
| inline composition (mixed families) | 1 | implemented (T4) | §3 |

**105 fixture pairs, 280/280 tests, 652/652 CommonMark.** The
convergence pairs in `tests/fixtures_test.zig` additionally prove the
shared renderer is byte-identical across dialects (Textile `*x*` ↔
Markdown `**x**`, `_x_` ↔ `*x*`, `"x":u` ↔ `[x](u)`, `!img.png!` ↔
`![](img.png)`, `# x` ↔ `1. x`).

**Remaining reference-documented forms, deliberately not implemented.**
Each is named with its provenance so the record is complete:

- `|filter|` block parameters (Textile 2 block signatures) — a
  processing pipeline, out of scope for a static renderer.
- The dash-marker definition-list form (`- term := definition`, current
  Textile docs; the `dl.` form is implemented) — the two references
  disagree (CLEANROOM session 18).
- List styling markers (`(class#id)* one` list-level vs `*(class#id)
  one` item-level) and multi-line list items — documented by Textile 2
  with one example each; items stay single-line (recorded ambiguity
  #20).
- Bracket/brace forcing (`c[*oo*]l`) — Textile 2's way to force
  intraword formatting; not inferred (the same position as `@code@`
  intraword, docs/TEXTILE-INLINE-CODE.md §2).
- The general letter+accent `{...}` macro pattern — only the documented
  forms are implemented (T20); the reference implementations' fuller
  table is outside the clean-room rule (CLEANROOM session 15).
- Inline `<notextile>...</notextile>` tags (current Textile docs; the
  block form is implemented) — a tag pair, not a block signature.
- `head_offset` and the CSS "caps" span — rendering options of the
  reference implementations, not syntax.
- Lists inside block quotes — in neither reference; deferred (chosen
  behavior #11).

