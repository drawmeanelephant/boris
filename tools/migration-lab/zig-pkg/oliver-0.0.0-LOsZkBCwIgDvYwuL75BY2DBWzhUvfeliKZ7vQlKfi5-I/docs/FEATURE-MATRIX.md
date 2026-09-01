---
published_at: 2026-08-14T00:00:00Z
summary: Oliver's feature matrix: implemented, planned, and deferred items across the Markdown frontend.
---

# Oliver Feature Matrix

Status legend:

- **implemented** — in the vertical slice, tested by fixtures/unit tests
- **planned** — designed, next milestones, behavior chosen from specs
- **deferred** — documented, deliberately not scheduled yet

The matrix is the record of *chosen* behavior. When documentation sources
disagree, the disagreement and Oliver's choice are recorded here.

---

# Markdown

Reference: CommonMark specification 0.31.2
(<https://spec.commonmark.org/0.31.2/spec.txt>). Oliver claims full
conformance to 0.31.2: the conformance gate runs the complete 652-example
corpus byte-for-byte and passes 652/652 with no named divergences
remaining (docs/COMMONMARK-EXPECTATIONS.md, docs/TESTS.md). The rows
below record the implemented surface; per-family scorecards give the
example counts behind that gate.

## Blocks

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| paragraphs | implemented | Consecutive non-blank lines; blank = only spaces/tabs (§3 "blank line"). §4.8: raw content is the concatenated lines with initial and final spaces/tabs removed. Oliver (slice, chosen): leading spaces/tabs are skipped on every line; trailing spaces/tabs are consumed by the break analysis (never emitted). Lines join with soft breaks unless the line ends in a hard break (§6.7). |
| ATX headings | implemented | §4.2. Opening 1–6 unescaped `#` preceded by ≤3 spaces, followed by space/tab or EOL. Content stripped of leading/trailing spaces/tabs. Optional closing run of *unescaped* `#`s (preceded by space/tab or comprising the whole content; followed only by spaces/tabs) stripped together with its preceding whitespace — backslash-escaped `#`s do not count in the closing sequence (§4.2 example 76). A single pass: in `# foo # #`, only the final `#` is a closing sequence (content `foo #`). `####### foo` is a paragraph. A terminal backslash stays literal because hard breaks do not occur at the end of a block (example 646). |
| Setext headings | implemented | §4.3, per docs/LEAF-BLOCKS.md. One or more `=`/`-` underline bytes with ≤3 leading spaces and trailing spaces/tabs transforms an eligible open paragraph; `=` → h1, `-` → h2. Content may span lines and is parsed as inlines; the final content line cannot create a hard break merely because the excluded underline follows. Leading link-reference definitions are registered but do not become heading content, and definitions alone are not an eligible heading. A Setext underline takes precedence over a dash thematic break, including one- and two-dash underlines that could otherwise become empty list items. It cannot be a lazy container continuation. **Scorecard: 27/27**. |
| thematic breaks | implemented | §4.1, per docs/LEAF-BLOCKS.md. Three or more matching `-`/`_`/`*` bytes, ≤3-column indent, with optional interleaved/trailing spaces or tabs; no other bytes permitted. Interrupts paragraphs and lazy container continuation, takes precedence over list items, and yields to an eligible Setext underline. Emits semantic `.thematic_break`; HTML uses the configured void-element style. **Scorecard: 19/19**. |
| block quotes | implemented | §5.1, per docs/BLOCKS-PARSING.md: a `>` marker (≤3 columns of indentation, one following column consumed — which may be a partially consumed tab) opens a container; markers nest (`> > foo`); laziness lets paragraph-continuation lines omit markers (`> foo` then `bar`), and omitting any number of initial `>`s is allowed on nested continuation lines; a truly blank line separates quotes while a marker-blank line (`>`) keeps one quote open; quotes can interrupt paragraphs; `>` alone is an empty quote. The container stack (spec appendix "A parsing strategy") is shared with list items and lists. **Scorecard: 25/25** (§5.1). |
| unordered lists | implemented | §5.2, §5.3. Bullet `-`/`+`/`*`; same-marker list merging; tight vs loose; nesting via content indentation; `<ul>`/`<li>` rendering. Content indentation and the whitespace after the marker are measured in columns, so tabs work as marker/indent whitespace (§2.1 Tabs examples 4, 5, 7, 9); five or more columns of whitespace after the marker makes the item's first block an indented code block (rule 2). |
| ordered lists | implemented | §5.2, §5.3. `1.`/`)` markers, nine-digit start numbers, same-delimiter merging, and `<ol start="…">` rendering. |
| fenced code blocks | implemented | §4.5, per docs/FENCED-CODE.md. Backtick or tilde opener of length ≥3 with ≤3 leading columns; same-marker closer at least as long, ≤3-column indent, trailing spaces/tabs only. Backtick info strings reject backticks; the complete trimmed info string resolves §2.4 backslash escapes and §2.5 entities, is retained, and its first word becomes an escaped `language-…` class. Content is literal, removes up to the opener indentation, normalizes every content line ending to `\n`, and closes without backtracking at the containing block/document end. Emits arena-owned `.code_block { content, info }` and deterministic `<pre><code>`. **Scorecard: 29/29**. |
| indented code blocks | implemented | §4.4. One or more chunks of lines each indented ≥4 columns (tabs expand to four-column tab stops), separated by blank lines. Cannot interrupt a paragraph; ends at the first line with <4 columns of indentation, so a paragraph may follow immediately. Content is the literal bytes minus four columns of indentation — a tab straddling the boundary leaves its remaining columns as spaces — with blank lines between chunks retained, trailing blank lines dropped, and one final newline. List and quote composition follows the container stack. Emits arena-owned `.code_block { content, info = null }`. **Scorecard: 12/12**. |
| HTML blocks | implemented | §4.6, all seven types, per docs/HTML-BLOCKS.md. Type 1 (`<script|pre|style|textarea`, case-insensitive), type 2 (`<!--`), type 3 (`<?`), type 4 (`<!` + letter), type 5 (`<![CDATA[`) end at their matching terminator on the line (`</script>` etc., `-->`, `?>`, `>`, `]]>`) or a blank line; type 6 (`<`/`</` + one of the 62 HTML block-tag names) and type 7 (a complete open/closing tag on its own line) end at a blank line (or containing-block boundary). Types 1–6 can interrupt a paragraph; type 7 cannot. Content is the container-stripped remainder with leading whitespace preserved, emitted verbatim as a `.html_block` leaf (pass-through policy, same as inline HTML). **Scorecard: 44/44**. |
| tables (GFM extension) | implemented | GFM §4.10 pipe tables in the Markdown frontend: header + delimiter (3+ hyphens, or 1+ with a colon) + body rows, leading/trailing pipes optional, `\|` escaped pipes, inline-parsed cells, alignment colons, `<table><thead><tbody>` output. Delimiter required; header/delimiter column counts must match; table ends at blank line or another block start. Cells are single-line (no blocks). Chosen behaviors where the GFM spec is silent are pinned in docs/TABLES.md. The contract-doc and assertion update points of recorded ambiguity 21 now point at docs/TABLES.md. |
| link reference definitions | implemented | §4.7: `[label]: destination ["title"]` collected during the block pass, before any inline parsing (a use may precede its definition). Extracted at paragraph close: the first line must be `[` + label + `]` + optional spaces/tabs + destination; an optional title may follow on the same line (separated by spaces/tabs) or on the next line; nothing else may follow the title on its line; indentation beyond 3 spaces cannot start a definition. First definition wins per label; labels are case-folded (Unicode full case fold, §6.3) with internal whitespace collapsed to a single space; an unclosed `[` cannot be a definition. Paragraphs consisting solely of definitions disappear from output; a definition may sit inside a paragraph of other content (the surrounding paragraph keeps its own inline pass). |
| blank lines | implemented | §3; whitespace-only lines separate blocks and are never part of content. |
| front matter (extension) | implemented | YAML (`---`) / TOML (`+++`) front matter sniffed at index 0 by the shared pre-pass (`src/frontmatter.zig`), stripped before dispatch so no frontend parses fence text, and parsed into `ParseResult.metadata` (Markdown/Textile) or `Recipe.metadata` (Cooklang) — a documented, bounded Oliver-chosen subset: top-level mappings, bare/quoted scalars kept as raw lexical bytes, scalar lists, indented maps (consistent deeper indentation), full-line comments; TOML adds `key = value`, `[table]`, `[[array-of-tables]]`; everything outside the subset (flow collections, inline comments, dotted keys, inline tables, tab indentation) keeps the **whole payload raw** with one `frontmatter-parse-unsupported` diagnostic — never faked, the Cooklang boundary rule extended; the strip happens regardless (front matter is never content); an unclosed opener passes through unchanged with `unclosed-frontmatter`; Cooklang's boundary-only `Frontmatter` converged onto the shared machinery (raw/span contract intact); opt-in `ParseOptions.frontmatter` (default off — an index-0 `---` is today a §4.1 thematic break); contract docs/FRONTMATTER.md; issue #66 (v0.5). |
| callouts (extension) | implemented | Obsidian-style callouts/admonitions: a leading `[!type]` immediately after the quote marker on a blockquote's first content line (`> [!note] Title`) turns the blockquote into a semantic callout (`<div class="callout callout-<type>">` with an optional `<div class="callout-title">`); the type is a non-empty run of ASCII letters/digits/`-`, case-insensitive, normalized to lowercase and preserved in the class (unknown types still render as `callout-<type>` boxes, Obsidian's behavior); the remainder of the first line is the title (inline-parsed — emphasis and wikilinks work, `callout_title_nodes`) and the rest of the blockquote is the body (nested containers, lists, code, and callout-in-callout all work through the existing container stack); malformed shapes (`[!note]x`, `[!]`, `[!no close`, mid-line `[!note]`) stay literal; off by default — a plain blockquote with literal `[!note]` text, so the corpus is untouched (`Options.callouts`); contract docs/CALLOUTS.md; issue #65 (v0.6). |

## Inlines

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| plain text | implemented | Text nodes are slices of the source. Rendering escapes `& < > "` and replaces NUL with U+FFFD (see docs/ARCHITECTURE.md). |
| soft breaks | implemented | Newline inside a paragraph → `soft_break` node → `\n` in HTML (CommonMark default, §6.8). A preceding single trailing space is consumed, not emitted. |
| hard breaks | implemented | §2.4/§6.7: two or more trailing ASCII spaces (tabs in the trailing run do not trigger a break) or an unescaped backslash before a following content line → `hard_break` → `<br />`. The trailing whitespace run (and a hard-break backslash) is consumed and never emitted. A single trailing space yields a soft break; the run is still consumed. A terminal backslash with no following content line remains literal (example 644); likewise, the final content line before a Setext underline cannot create a break into the excluded underline. |
| backslash escapes | implemented | §2.4: `\` + any ASCII punctuation escapes it (produces that character literally); backslashes before other characters are literal; `\\` → literal `\` (escape-aware, example 15). Escapes are recognized in ATX closing-sequence detection (§4.2 example 76) and in end-of-line hard-break analysis (`foo\\` is a literal backslash + soft break). Each escape splits the text into adjacent text nodes with exact source spans; contiguous spans merge into one text node (§6.2 milestone). |
| entities | implemented | §2.5, per docs/ENTITIES.md. Named references decode against the full WHATWG HTML5 entity list (2,125 semicolon-terminated names — entities.json's ~2,231 entries minus the no-semicolon legacy forms, which §2.5 excludes; generated into src/entities.zig from html.spec.whatwg.org entities.json via tools/gen-entities.py, mirroring the unicode.zig pattern); numeric references decode hex/decimal with the spec's range rules — invalid codepoints and surrogates become U+FFFD, a decoded tab/carriage-return/line-feed is emitted literally. Decoding happens at render time in the text writer (escaped chars are still escaped, e.g. `&lt;` → `&lt;`) and at parse time in link/image destinations + titles, autolinks, image alt flattening, and fenced info strings; backslash-escaped `&` is never decoded (the escape splits the text node so the renderer sees the escaped char). Not decoded in code spans or code blocks. Requires a trailing `;`; bare names like `&copy` stay literal. **Scorecard: 17/17** (§2.5). |
| emphasis / strong | implemented | §6.2, full rule set (rules 1–12) with the scan → match → emit algorithm in docs/INLINE-PARSING.md: per-run flanking classification, a delimiter stack with `openers_bottom` pruning (amortized linear), the mod-3 rule, strong-before-emphasis, and front/back run consumption for intraword runs that act as both closer and opener. Unicode whitespace/punctuation classification comes from generated tables (src/unicode.zig, Unicode 13.0 categories Zs / P+S per §2.1). Adjacent text nodes merge when their spans are contiguous (normalized model). Verified against spec examples 384–418 including `***foo** bar*`, `*****Hello*world****`, `foo_bar_baz`, `5__6__78`, `пристаням__стремятся__`. |
| code spans | implemented | §6.1: backtick-string discovery runs ahead of delimiter matching; an opener closes at the next backtick string of equal length (opening 2 vs closing 1 does not match); unmatched backticks stay literal. Content is opaque to delimiters and backslash escapes are inert inside; line endings become spaces; one ASCII space is stripped from each end when the content begins and ends with space but is not all spaces (tabs are not stripped, spec 344's note); the closer scan ignores backslash escapes (spec 340). `code_span` is a leaf inline with arena-owned normalized content; the node span covers the whole construct including backticks. Verified against spec examples 333–348. |
| links | implemented | §6.3 (inline links + reference forms): link-bracket discovery runs ahead of delimiter matching (brackets bind more tightly than emphasis; `*[foo*](/uri)` is a link), and code spans bind more tightly than brackets. A `]` whose nearest `[` is followed by a valid `(...)` forms an inline link; otherwise the full `[text][label]`, collapsed `[text][]`, and shortcut `[text]` reference forms are tried against the collected definitions (§4.7), in that order; a `(` after the `]` that fails to parse as an inline destination does *not* block the shortcut form (spec example 561), and reference forms cannot contain other reference links in their labels. Brackets that never resolve stay literal. Inline destination/title syntax per spec: `<...>` or bare destinations (balanced/escaped parens only), `"`/`'`/`(...)` titles, components separated by spaces/tabs/up to one line ending, destinations cannot contain line endings, titles may. A valid link kills every earlier `[` (links cannot contain links, innermost wins); link text is matched as a fresh inline scope. Destinations and titles resolve backslash escapes into arena-owned payloads (`data.link`); href percent-encoding is a renderer policy (see docs/ARCHITECTURE.md). **Chosen behaviors/divergences:** a paren-title closes at the first unescaped `)`; an unescaped `<` inside an angle destination fails the link; DoS guards — paren depth capped at 32 (spec-sanctioned) and component scans capped at 2048 bytes. Destinations and titles also resolve §2.5 entities (`&amp;` → `&`) before escaping, per the spec. Verified against spec examples 482–536 (inline subset) plus the §6.3 reference-link examples. |
| images | implemented | §6.4, see docs/IMAGES-PARSING.md. `![` (unescaped `!` + `[`) is its own opener on the same discovery stack as links; an image description may contain links and images, so only a formed *link* inactivates earlier `[` openers — never `![` (the spec appendix's active/inactive rule, implemented as an O(1) monotone check). The description is matched as a fresh inline scope and flattened to the arena-owned `alt` string ("only the plain string content" — an autolink in the description contributes its raw label, `![<http://x>](img)` → `alt="http://x"`); `.image` is a leaf inline (`data.image = { src, alt, title }`). `<img src alt title>` renders as a void element under `void_trailing_slash`; `src` uses the link `href` percent-encoding policy; `alt` is always emitted (possibly empty) and `title` only when present, both HTML-escaped like text; attribute order is fixed `src`, `alt`, `title`. Destinations/titles parse identically to links and share the §6.3 DoS guards (paren depth 32, scan cap 2048). **Reference forms implemented:** `![alt][label]`, `![alt][]`, and `![alt]` resolve through the §4.7 definition table with the same full→collapsed→shortcut ordering as reference links (docs/REFERENCE-IMAGES.md); the description flattens to `alt` identically, and a formed reference image inactivates nothing (same monotone rule). |
| autolinks | implemented | §6.5, see docs/AUTOLINKS.md. A `<` is recognized ahead of link/image bracket parsing (brackets and code spans do not intercept it) when it starts a URI autolink (scheme 2–32 chars, then `:`, then content up to the first `>`; content forbids ASCII control, space, and `<`) or an email autolink (the non-normative HTML5 email regex, anchored: local part + `@` + dot-separated labels of at most 63 chars, each alphanumeric-bounded and ending alphanumeric). URI content may contain `\`, `]`, and `(` freely — those are *not* escapes or link syntax inside an autolink (spec example 526: `](uri)` lands in the href). Emits one `.autolink` leaf (`data.autolink = { href, label }`); the label is the raw content verbatim (backslash escapes are inert inside autolinks — the payload is *not* escape-resolved, unlike `data.link`), and the href is the content for URIs or `mailto:` + content for emails. Renders `<a href="...">label</a>` with deterministic escaping and percent-encoding. Recognition is linear; verified byte-for-byte against all 19 §6.5 examples. |
| inline HTML | implemented | §6.6: open/closing tags, comments, processing instructions, declarations, and CDATA sections are discovered across paragraph lines, kept opaque to delimiters/links, and rendered verbatim from their source spans. Invalid shapes remain escaped text; custom tag names are allowed. The renderer policy for this slice is pass-through (as is the §4.6 HTML-block family, now complete); configurable escaped/rejected modes remain planned. See docs/RAW-HTML.md. |
| Unicode | partial | Bytes pass through untouched; no encoding assumptions beyond byte slicing. Text escaping operates on bytes; multibyte UTF-8 is unaffected. |
| NUL | decided | Kept in the model (source bytes preserved), replaced with U+FFFD at render time. CommonMark replaces at parse time; divergence recorded deliberately because Oliver preserves source fidelity in spans. |
| wikilinks (extension) | implemented | Obsidian-style `[[Page Name]]` / `[[Page Name|Custom Label]]` inline wikilinks — a `.wikilink` leaf (`target`/`label`, both source slices), resolved at render time by an optional resolver fn + opaque context on `html.RenderOptions` (default: target percent-encoded as the href, `label orelse target` as the visible text); recognized ahead of link brackets with an atomic literal fallback; malformed shapes (unterminated, empty/whitespace target, empty label, `[[a|b|c]]`, `[[` inside the target) stay literal; opaque in code spans/blocks, autolinks, link destinations/titles, image src/alt/title, link display text, and image descriptions (a wikilink inside `[text]` stays literal — no nested `<a>`); off by default (`Options.wikilinks`); contract docs/WIKILINKS.md; issue #64 (v0.5). |
| smart typography (extension) | implemented | opt-in `smartypants`: the Textile character-replacement passes (curly quotes by direction, `--` → em dash, space-surrounded `-` → en dash, `...` → ellipsis, digit-adjacent `x` → dimension sign, the parenthesized symbols) in **one shared implementation** (`src/typography.zig`, extracted from Textile with byte-identical output — the Textile wall is the net) and applied to CommonMark plain `.text` nodes in every inline scope (paragraphs, headings, list items, GFM table cells, link display text, callout titles/bodies) with the Textile exemption set (code spans/blocks, autolinks, raw HTML tags, link destinations/titles, image src/alt/title, wikilink targets/labels, escaped `\"`/`\'` — the escape split exempts the byte); the `{...}` character-macro table stays Textile-only (braces literal); borrow-or-copy payloads; off by default (`Options.smartypants`); contract docs/SMARTY.md; issue #67 (v1.0). |

## Inline parsing (origin, not imitation)

Emphasis/strong is implemented with an explicit delimiter algorithm derived
from the spec's own rules (§6.2) — see docs/INLINE-PARSING.md, which was
written as the design contract *before* any code: scan delimiter runs and
classify flanking, match on a delimiter stack with the mod-3 rulebook and
`openers_bottom` pruning, then emit emphasis/strong pairs with exact source
spans. Malformed delimiter input degrades to literal text predictably.

Links, code spans, raw HTML, and escapes are recognized by scanning *before*
delimiter matching in a documented precedence order (code span markers are
opaque to delimiters; raw HTML is opaque to delimiters and link brackets; link
brackets are opaque to emphasis), exactly as §6.1's precedence requires. The
code-span precedence landed with the
code-span milestone; the link precedence (a second discovery pass with its
own bracket stack) landed with the link milestone; images (`![` openers,
with the appendix's active/inactive bracket semantics) extended that same
pass with the images milestone (docs/IMAGES-PARSING.md, written as the
design contract *before* the image code). Raw HTML uses a whole-paragraph
discovery pass merged with code spans so the first construct at the earliest
source position wins.

---

# Textile

Sources: Hobix "Textile Reference" (Dean Allen,
<https://hobix.com/textile>), Movable Type "Textile 2 Syntax" (Brad
Choate, <https://movabletype.org/documentation/author/textile-2-syntax.html>),
and the Textile Markup Language Documentation
(<https://textile-lang.com/doc/block-quotations>). These are user-facing
syntax documents, not parser code.

Textile is a first-class dialect. Where the references disagree, Oliver
records the disagreement and chooses one behavior (see "Recorded ambiguities"
below).

## Blocks (Textile)

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| paragraphs | implemented | Blank-line separated (`p.` default signature, both references). Bare text or `p.`-prefixed; a `p.` marker must be followed by a space/tab to count and interrupts an open block even without a preceding blank line. Content is preserved verbatim (only the marker's separator whitespace is consumed). |
| headings | implemented | `h1.`–`h6.` markers, each followed by a space/tab. `h0.`/`h7.`+ are not headings (paragraph text). `hN.` at end of line (no space) is not a heading. Content after the marker is verbatim. |
| line breaks | implemented | Newline inside a paragraph → hard break → `<br />`. Textile 2 is explicit ("newlines for XHTML content receive a `<br />` tag at the end of the line, with the exception of the last line in the paragraph"); Hobix prose agrees ("Line breaks are converted to HTML breaks") though its rendered example shows a plain newline — recorded below. |
| block quotes | implemented | Single-period `bq.` from the Hobix Textile Reference, Movable Type Textile 2 Syntax, and the current Textile Markup Language Documentation. The signature must be followed by space/tab; all separator whitespace is consumed. Unmarked following lines continue one paragraph inside `.block_quote` with Textile hard breaks until a blank line or a recognized `p.`, `hN.`, or `bq.` signature; signatures interrupt an open block. The quote and child paragraph spans exclude the marker/separator and cover their content. An empty `bq. ` stays literal because the sources do not specify empty quote behavior. Extended `bq..` is implemented (see the extended-blocks row). |
| block-quote citations | implemented | `bq.:URL` — a citation URL immediately following the period (the current Textile docs' block-quotations page; Learn X in Y Minutes agrees) — renders as the blockquote's `cite` attribute, which follows the link href policy (percent-encoding, trailing-punctuation trim): `bq.:http://textpattern.com/ A cited quotation.` → `<blockquote cite="http://textpattern.com/"><p>…</p></blockquote>`. The §8 block modifiers combine (`bq{color:red}.:URL` — cite first, then attrs). `bq.:` with no URL, a space after the colon, no content, no separator, or the undocumented `bq..:URL` extended-citation form all stay literal. A citation signature terminates an open extended block. Pinned in docs/TEXTILE-PARITY.md §12. |
| pre/code | implemented | `bc.` block code and `pre.` preformatted text open a leaf that owns every following non-blank line verbatim until a blank line (Textile 2: "a block ends with the first blank line"), so signature-shaped lines stay code content. `bc` renders `<pre><code>` with `<`/`>` escaped automatically (Textile 2); `pre` renders verbatim `<pre>` with no escaping (current Textile docs). Block-attribute modifiers work on both (`bc{color:red}.`, attrs on the `<pre>`). The extended `bc..`/`pre..` forms are implemented (T12) — see the extended-blocks row. Pinned in docs/TEXTILE-PARITY.md §9. |
| lists | implemented | `*` unordered, `#` ordered; nesting by repeating the marker (`**` = nested), per both references. Each item is one line; lists are tight; a blank line, a block signature, or a non-marker line closes the list tree. A different marker at the same depth starts a sibling list; a depth jump opens empty intermediate items; `*#` runs or markers without a following space/tab are ordinary text (docs/TEXTILE-PARITY.md §3). Styling markers (`(class#id)* one` vs `*(class#id) one`) and multi-line items remain deferred. |
| definition lists | implemented | `dl. term:definition` (Textile 2 "Definition lists"), the audit's last block deferral (T23): the term sits at the line start (or right after the signature) immediately followed by `:`, the definition is the rest of the line, and a definition may span multiple lines — a line without a `term:` prefix continues the open definition. Converges on the shared list model as a `.definition` kind whose items carry their term/definition role, rendering `<dl>`/`<dt>`/`<dd>`; `dl<mods>.` attrs land on the `<dl>`. A signature without a `term:` prefix, an empty term or definition, or an empty signature stays literal. The current Textile docs document a **different** dash-marker form (`- term := definition`) — recorded, not implemented. Pinned in docs/TEXTILE-PARITY.md §21. |
| tables | implemented | `|a|b|` rows compose a table block (single-line rows; a row must start and end with `|`); an optional `table<mods>.` signature opens one, alone (Hobix) or followed by the first row (Textile 2). Cell modifiers — `_` header, `<`/`>`/`=`/`<>` alignment, `^`/`~` valign, `\2` colspan, `/2` rowspan, `{style}`, `(class)`/`(#id)`/`(class#id)`, `[lang]`, `(`/`)` padding — are terminated by a period followed by a space (the documented contract); row modifiers end at the first `|` (Textile 2) or after `. ` (Hobix). A header cell's alignment becomes the default for the cells below it in the same column (Textile 2). Output is flat `<tr>`/`<th>`/`<td>` rows (no thead/tbody) with attributes in the fixed render order style/class/id/lang; alignment renders as CSS `style` (Hobix), not the GFM `align` attribute. Every other row/signature shape stays literal. Chosen behaviors are pinned in docs/TEXTILE-PARITY.md §6. |
| footnotes | implemented | `[N]` references → `<sup class="footnote"><a href="#fnN">N</a></sup>` (Textile 2's classed form; Hobix renders without the class); `fnN.` blocks render `<p class="footnote" id="fnN"><sup>N</sup> body`. The §8 block modifiers apply to `fnN.` signatures — the structural `class`/`id` always come first and user style/lang follow (`fn1{color:blue}.`). Any digit run is allowed (`[12]`), numbers beyond `u16` and non-digit brackets stay literal, and empty `fnN.` signatures stay literal. `fnN.` also terminates an open extended block. Pinned in docs/TEXTILE-PARITY.md §11. |
| escaping blocks | implemented | `==` delimited regions (Textile 2 "Escaping") — a lone `==` line (trailing whitespace allowed) opens a region whose content passes through as a raw `.html_block`, unformatted and unescaped, for dropping regular HTML into the document; the region runs to the next lone `==` line (or end of input) and blank lines inside are content. The delimiter check runs before every other block rule, so a `==` line interrupts paragraphs, lists, tables, and open code blocks alike. An empty region renders nothing. `notextile.`/`notextile..` (the audit's last deferral) is now implemented as the signature form of the same mechanism — see the raw passthrough row. Pinned in docs/TEXTILE-PARITY.md §14. |
| raw passthrough | implemented | `notextile.`/`notextile..` (current Textile docs "No formatting (override Textile)"; Textile 2 does not document the form, using `==` instead — recorded in CLEANROOM session 20) at the start of a block skips Textile processing entirely: the content passes through as one raw `.html_block` leaf — no inline formatting, no character replacements, `<em>` stays a real tag, `*Textilised*` stays literal — byte-for-byte from the source (CRLF preserved), the signature form of the `==` escape. The single period owns every following non-blank line, ending at the first blank line (like `bc.`); the double period keeps blank lines as content and runs until the next block signature (like `bc..`). A bare marker with no same-line content opens a block whose content is the following lines; an empty block renders nothing. The marker is a block signature (it closes open extended blocks and definition lists), is code content inside a single-period `bc.`, and is interrupted by a `==` delimiter like every block; a pending `clear.` has no attribute list to land on and is dropped. Every other shape — a word merely starting with "notextile", a missing period, a non-space after the period, mid-paragraph — stays ordinary text. Pinned in docs/TEXTILE-PARITY.md §23. |
| block attributes | implemented | `{style}`, `[lang]`, `(class)`, `(#id)`, `(class#id)`, alignment `< > = <>` (→ `text-align` style), padding `(`/`)` (→ `padding-left/right` em), all combinable between the marker and its period for `p`, `bq`, and `hN` signatures: `h2()>. Bingo.` → `<h2 style="padding-left:1em; padding-right:1em; text-align:right;">`. The modifiers must be terminated by a period followed by a space/tab; every other shape stays literal. A multi-declaration `{style}` is normalized the way Hobix renders it (`{color:blue;margin:30px}` → `color:blue; margin:30px`); an empty class or id is omitted (`p(#big-red).` → `<p id="big-red">`). A bare `(` directly before the period is left padding (`p(.` needs no closing paren). `bq` attributes land on the `<blockquote>`; the inner paragraph stays unmarked. Chosen behaviors are pinned in docs/TEXTILE-PARITY.md §8. |
| line attributes | implemented | The `|mods|.` line-level form: a line beginning with a pipe, a §8 block-modifier run, a closing pipe, a period, and separator whitespace applies the modifier set to the paragraph — `|{color:red}(note#one)>[fr]|. Styled` → `<p style="color:red; text-align:right;" class="note" id="one" lang="fr">`, byte-identical to `p<mods>.`. It behaves like a paragraph signature (interrupts open paragraphs, terminates extended blocks) and is not a table row (rows must end with `|`). Every malformed shape — no closing pipe, a dot-terminated run, no period, no space after the period, empty modifiers, empty content, a row/cell-only token — stays literal. Provenance: the pipe form is not in the clean-room references (Textile 2's pipe-delimited block parameter is the `|filter|` filter); it follows the user's specification on the documented §8 set, recorded in docs/CLEANROOM.md session 12 and pinned in docs/TEXTILE-PARITY.md §15. |
| extended blocks | implemented | `bq..` stays active across blank lines (one `<blockquote>` of blank-line-separated paragraphs), and `bc..`/`pre..` keep blank lines as verbatim code content — both run until the next block signature (Textile 2 "Extended Blocks": "until the next signature is found"; the current docs: terminated by any other text block signature). Optional block modifiers sit before the double period (`bq{color:red}..`). List markers, table rows, and plain lines are not signatures, so they remain content; def lines still vanish (and stay code inside `bc..`). `p..`/`hN..` and empty `sig..` signatures stay literal. Pinned in docs/TEXTILE-PARITY.md §10. |

| `clear` signature | implemented | `clear.` (clear both), `clear<.` (clear left), `clear>.` (clear right) — a lone marker line (only trailing whitespace after the period, or the `<`/`>` direction) that renders nothing; the next block to open carries `style="clear:both;"` (or `left`/`right`) in its attribute set, merged ahead of any style the block already has (Textile 2 "clear": "the next block should emit a CSS style attribute that clears any floating elements"). Applies to every block family — paragraphs, headings, block quotes, lists, tables, definition lists, footnotes, code blocks — and closes whatever block was open (an extended `bq..`/`bc..` or definition list ends at the marker; a single-period `bc.` owns the marker as code content). A dangling marker at end of input is dropped; any other shape — content after the marker, a different modifier, a word merely starting with "clear" — stays ordinary text. Pinned in docs/TEXTILE-PARITY.md §22. |

## Inlines (Textile)

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| plain text | implemented | Verbatim bytes; escaped at render like Markdown (shared renderer). |
| emphasis `_x_` | implemented | → `<em>`. Both references agree. Same-line, with the shared whitespace/punctuation boundary contract (docs/TEXTILE-PARITY.md §3). |
| strong `*x*` | implemented | → `<strong>`. Both references agree. Same boundary contract. |
| bold `**x**` / italic `__x__` | implemented | → `<b>` / `<i>`. Both references agree (Hobix: "doubling the underscores or asterisks"). Runs of 3+ stay entirely literal. |
| deleted `-x-` / inserted `+x+` | implemented | → `<del>` / `<ins>`. Both references agree. |
| superscript `^x^` / subscript `~x~` | implemented | → `<sup>` / `<sub>`. Both references agree. |
| code `@x@` | implemented | Same-line code phrase → shared opaque `.code_span` → `<code>`; payload bytes are verbatim and the full `@...@` source range is the node span. Textile 2 explicitly requires `<`/`>` escaping; the shared renderer also escapes `&`, `"`, and NUL. Open/close operators must touch non-whitespace content and use outside Unicode whitespace/punctuation boundaries; intraword, empty, edge-whitespace, unmatched, embedded-`@`, and cross-line shapes fall back literally. Backslash has no escape role in the cited references. Exact clean-room contract: `docs/TEXTILE-INLINE-CODE.md`. |
| citation `??x??` | implemented | → `<cite>` (Hobix: "Use double question marks to indicate citation" — `??Cat's Cradle?? by Vonnegut` → `<cite>Cat’s Cradle</cite>`, the curly-apostrophe replacement applying inside like any phrase). A doubled `?` run is a phrase operator: it accepts the phrase-attribute run (`??{color:red}x??` → `<cite style="color:red;">`) and nests the other operators through the shared machinery (a delimiter that qualifies as both opener and closer tries to close first, then opens — the fix that lets `??_(big)x_??` nest). A lone `?` or a run of 3+ stays literal; the family's malformed/whitespace/no-content mods-run fallbacks apply. Pinned in docs/TEXTILE-PARITY.md §20. |
| acronyms | implemented | `ABC(def)` → `<acronym title="def">ABC</acronym>` (Hobix: "Definitions for acronyms can be provided by following an acronym with its definition in parens" — `CSS(Cascading Style Sheets)`). A run of 2+ uppercase letters at an inline boundary directly followed by a non-empty parenthesized definition; the definition closes at the first `)`, is the `title`, and is opaque to phrases/replacements. Single letters (`I(think)`), intraword runs (`xCSS(no)`), and empty/unclosed definitions stay literal; `@code@`/link display text are opaque. Pinned in docs/TEXTILE-PARITY.md §20. |
| span `%x%` | implemented | → `<span>`. Both references agree. The phrase-attribute forms are implemented (T20): `%{style}(class#id)[lang]x%` composes through the block-attribute machinery into `<span style="…" class="…" id="…" lang="…">` (Hobix "Phrase Attributes": all block attributes apply just inside the opening modifier — `%[es]cabeza%` → `<span lang="es">cabeza</span>`; Textile 2 "Inline formatting operators accept the following modifiers" — style/lang/class-id only, no padding/alignment). A malformed run stays literal; a run with no content after it (`%(x)%`) falls back to a plain span; a `%` inside a style value cannot close the span. Pinned in docs/TEXTILE-PARITY.md §18. |
| phrase attributes (all operators) | implemented | **Extended to every phrase operator (T21)** per Hobix "Phrase Attributes": "all block attributes can be applied to phrases as well by placing them just inside the opening modifier" — `*{color:red}x*` → `<strong style="color:red;">x</strong>`, `_(big)x_` → `<em class="big">x</em>`, and the doubled/long operators (`**{...}x**`, `--{...}x--`) compose through the same machinery onto the phrase's own HTML tag. Same fallback contract as the span forms: a malformed run stays literal, a run followed by whitespace is not an opener, a run with no content after it falls back to a plain phrase whose content includes the run bytes, and an operator char inside a style value cannot close the phrase. A `--` that cannot form a pair still em-dashes. Pinned in docs/TEXTILE-PARITY.md §19. |
| big `++x++` / small `--x--` | implemented | → `<big>` / `<small>` (Textile 2 "Inline Formatting"), the last phrase-family gap, implemented per the user's request. A doubled run forms the phrase when both delimiters sit at the inline boundaries; runs of 3+ stay entirely literal, and a `--` that cannot form a pair still becomes an em dash through the character-replacement pass (`a -- b`, `foo--bar`, `2--4`, unmatched `--x`/`x--`). The delimiters of a matched pair are consumed, so `--smaller--` renders `<small>smaller</small>`, never `—smaller—`. Single-length `-x-`/`+x+` del/ins are unchanged. Pinned in docs/TEXTILE-PARITY.md §17. |
| links | implemented | `"text":url`, optional `(title)` inside the quotes (both references). URL runs to whitespace or `)]}`; trailing sentence punctuation is excluded (Hobix); the bracket trick `You["gotta":url]seethis!` works (Textile 2). Display text is plain text (not re-scanned). **Link aliases implemented (T9):** `[alias]url` lines anywhere in the document define aliases (first definition wins; exact, case-sensitive matching; the line never renders), and `"text":alias` resolves to the defined URL even when the definition comes later — the Textile mirror of the Markdown §4.7 definition table (docs/TEXTILE-PARITY.md §7). An undefined alias stays a relative URL. Image link attachments (`!url!:href`) stay direct-URL only. See docs/TEXTILE-PARITY.md §3. |
| images | implemented | `!url!`, alt `(alt)` (Hobix) / ` (alt)` (Textile 2), link attachment `!url!:href` (Hobix), and the modifier set (T18): alignment `<` left / `>` right (→ `float`), `=` centered (→ `display:block;margin:0 auto`), `-` middle / `^` top / `~` bottom (→ `vertical-align`), `{style}`, `(class#id)` (spaces allowed in the class, per the current docs), and `(`/`)` padding — all composing through the block-attribute machinery into the `.image` attrs in the pinned order; plus the Textile 2 sizing forms `10x20`, `10w 20h`, `20%x40%`, and a single proportional `20%` → `width`/`height`. The alt doubles as the title per the Hobix example. Malformed modifiers, junk post-src tokens, size+alt combinations, and whitespace-containing srcs stay literal. Pinned in docs/TEXTILE-PARITY.md §16. |
| escaping | implemented | `==...==` inline region (Textile 2 "Escaping"; the current docs' special-characters page: "the Textile formatting can be temporarily suspended by wrapping the text passage into =="). The delimited span suspends all inline formatting and the character replacements and renders as literal text (still HTML-escaped at render like any text). The opener must sit at an inline boundary and be exactly `==`; the content is non-empty and runs to the first following `==` that also sits at an inline boundary, else the whole construct stays literal. The emitted node's span is the inner content only, so the delimiters keep it from merging with neighboring text (model invariant 11). Inside `@code@`, link display text, and image src/alt the `==` is opaque. Backslash escaping varies by version and stays unresolved. Pinned in docs/TEXTILE-PARITY.md §14. |
| character replacements | implemented | Applied to plain text in the Textile inline pass: straight `"`/`'` become curly (direction by the surrounding source bytes), `--` → em dash (a `--` that forms a matched phrase pair is consumed by the phrase scanner instead — see the big/small row), a space-surrounded `-` → en dash, `...` → ellipsis, a digit-adjacent `x` → dimension sign (×), and the documented parenthesized symbols `(c)`/`(r)`/`(tm)` (case-insensitive) → ©/®/™, `(1/4)`/`(1/2)`/`(3/4)` → ¼/½/¾, `(o)` → °, `(+/-)` → ±. HTML-looking `<...>` regions and verbatim payloads (`@code@`, code blocks, link/image src/alt/title) are exempt; the replacements apply inside phrase content and link display text (Hobix renders `it's` inside a link as a curly apostrophe). Replaced text is an arena-owned payload; untouched text still borrows the source. A run of 3+ hyphens/periods is replaced left-to-right (`---` → `—` + `-`). **Textile 2's `{...}` character-macro table is implemented (T20):** the documented forms with their mirrored orders (`{c|}`/`{|c}` → ¢, `{L-}`/`{-L}` → £, `{Y=}`/`{=Y}` → ¥, `{A'}`/`{'A}` → Á, `{a"}`/`{"a}` → ä, `{1/4}` → ¼, `{*}` → •, `{:)}` → ☺, `{:(}` → ☹); phrase operators at a brace edge are not recognized, so the brace region stays whole; every other `{...}` shape stays literal (the general letter+accent pattern beyond the documented examples is deferred). Pinned in docs/TEXTILE-PARITY.md §18. |
| whitespace sensitivity | implemented | Textile 2: inline operators need whitespace before/after to be recognized; brackets/braces can force recognition. The boundary rule (Unicode whitespace or punctuation/symbol before an opener and after a closer, non-whitespace content edges) is implemented uniformly for `@code@`, every phrase operator, links, and images (docs/TEXTILE-PARITY.md §3). Bracket/brace forcing stays planned. |

## Cooklang

Cooklang (`*.cook`) is a first-class Oliver frontend (CK1) with its **own
typed Recipe model** (`src/cooklang.zig`): it does not converge on the
Markdown/Textile `document.Document` IR because recipe semantics
(ingredients, quantities, units, cookware, timers, preparations, recipe
references, sections, notes, metadata) must survive parsing as typed
data. It reuses Oliver's infrastructure: spans, diagnostics, arena
ownership, byte borrowing, `source.Lines`, and the unicode predicates.
The full design contract, source hierarchy, provenance, and chosen
behaviors are in docs/COOKLANG.md and CLEANROOM session 21. The
canonical corpus (`cooklang/spec` `tests/canonical.yaml` v7, pinned
commit, MIT) is the executable conformance wall
(`zig build cooklang-conformance`).

| feature | status | Oliver behavior / notes |
| --- | --- | --- |
| ingredients `@name` / `@multi word{}` | implemented | the name region runs to the first `{` on the line but stops early at a following token marker (`@`/`#`/`~`), at P-category punctuation, or at a non-`-`/`.`/`/` boundary — so the spec's own `@salt and @ground black pepper{}` is two ingredients (pinned; the raw EBNF reading would name the whole run, and the corpus never distinguishes it); single-word names end at Unicode whitespace or P-category punctuation (symbols like `🧂` stay in names — canonical `testIngredientWithEmoji`); quantity/units are source text inside `{}`/`%` (never coerced; a derived numeric view exists for pure numeric forms); empty braces and absent braces leave `quantity: null` (canonical defaults `"some"`/`1`/`""` applied by the conformance harness per type); invalid tokens (`@ example`) degrade to text. |
| cookware `#name` / `#multi word{}` | implemented | same name/quantity contract as ingredients; quantity present in braces (`#frying pan{2}`, `{three}`, `{two small}`). |
| timers `~{...}` / `~name{...}` / `~name` | implemented | named (`~eggs{3%minutes}`) and unnamed (`~{25%minutes}`) forms; single-word named timers without braces (`~rest`); quantity/units preserved as source text; invalid forms (`~ {5}`) degrade to text. |
| steps | implemented | paragraphs separated by blank lines; a step is a list of parts (text/ingredient/cookware/timer/line-break); multi-line steps join with a single space (canonical); a line ending in `\` forces a line break. |
| comments `--` / `[- -]` | implemented | line comments run to end of line, block comments may span lines; both are omitted from the semantic tree (canonical `testComments`); an unclosed `[-` degrades to literal text with an `unclosed-block-comment` warning. |
| notes `> text` | implemented | a `>`-prefixed paragraph (proposal 0005, Released); continuation lines may or may not carry `>`; content is plain text (not scanned for tokens); one paragraph per note block; no nesting. |
| sections `= Name` / `== Name ==` | implemented | 1+ leading `=`, optional name, 0+ trailing `=`; title is plain text; steps after a header belong to that section until the next header or EOF (proposal 0006, Released). |
| shorthand preparations `@x{1}(peeled)` | implemented | the `(...)` after the braces stays associated with its ingredient. |
| recipe references `@./path{2}` | implemented | an `@` token whose name starts with `./` is flagged `is_recipe_reference`; the path is preserved as the name; Oliver never resolves it (filesystem resolution is a consumer responsibility). `.menu` files use sections + references and parse through this frontend. |
| YAML front matter | implemented (boundary only); parsed metadata shipped with the option on | `---` fences at the very start of the file; the raw payload is preserved with exact spans as `Frontmatter`; Oliver does not parse arbitrary YAML (no fake subset); a missing closing fence degrades to step text with an `unclosed-frontmatter` warning. The shared frontmatter extension (issue #66, v0.5) converged `tryFrontmatter` onto one sniff/strip pre-pass for all three frontends (`src/frontmatter.zig`): with `ParseOptions.frontmatter = .yaml`, `Recipe.metadata` exposes the parsed view beside `raw` (bounded Oliver-chosen subset; out-of-subset payloads stay raw with a diagnostic); `.none` keeps the boundary-only behavior byte-identical. |
| HTML rendering | Oliver policy (CK4) | a deterministic, Oliver-owned vocabulary (`src/cooklang_html.zig`), separate from the Markdown/Textile renderer; explicitly **not** "Cooklang-conformant" (the spec defines no HTML). The richer generic policy adds: an **ingredients index** (`<section class="ingredients">`, one `<li>` per distinct ingredient in first-appearance order — exact case-sensitive name, first occurrence's quantity/units/preparation, visible `<span class="quantity">` and `<span class="preparation">`, recipe references as `recipe-ref` items, cookware/timers excluded, omitted when empty), timers as `<time class="timer" datetime="PT25M">` (ISO-8601 duration for whole-number quantities with recognized day/hour/minute/second units, case-insensitive; named timers render `name (3 minutes)`), unnamed sections omit the empty `<h2>`, and preparations surfaced in the index. Frontmatter is not rendered (data, not content). Aggregating quantities / shopping lists stays ecosystem logic. |
| canonical serialization | implemented (CK2) | `src/cooklang_serialize.zig` turns a semantic `Recipe` back into valid `.cook` — deterministic and idempotent (`serialize(serialize(x))` is byte-identical, `parse(serialize(parse(x)))` is semantically identical). **Canonical, not byte-identical round-tripping**: the parser normalizes spelling (marker style, whitespace, `== Name ==` → `= Name`, comment placement), so the output is one valid spelling of the same recipe; a byte-identical round-trip would need a CST/trivia layer and is out of scope (docs/COOKLANG.md §10). Front matter passes through byte-for-byte; braces/units/preparations/breaks emit exactly what the model says they carried; empty front matter (`---\n---`) round-trips. Exposed as `oliver.cooklang_serialize.serialize` and `oliver serialize --from cooklang`; the conformance harness asserts the fixed point over every corpus source; `serialize-basic`/`serialize-literal` fixture pairs pin canonical output. |
| `.menu` profile view | implemented (CK5) | `src/cooklang_menu.zig` — the explicit convenience layer over the existing Cooklang frontend (`.menu` files are valid Cooklang, so there is no second parser): `menuView` exposes the day/meal structure semantically (`Menu { days: []Day }`, `Day { name, date, references }`, `Reference { path, quantity, units }`). Every top-level section is a day in order; an ISO date is recognized only as a trailing `(YYYY-MM-DD)` title group (valid month/day); reference directives (`{2}`, `{}`, `{4%servings}`) are preserved as source text, never deduplicated or resolved; non-section top-level blocks are not part of the view. `writeMenu` renders a deterministic text dump (shared by `oliver menu --from cooklang` and the `menu-basic` fixture pair, which is the conventions' own example). A view, not meal-planning logic — shopping/scheduling/filesystem access stay consumer-owned. 6 unit tests. Docs/COOKLANG.md §12. |
| scaling (pure semantic operation) | implemented (CK3) | `src/cooklang_scale.zig`: public string primitives `classifyQuantity` / `parseFactor` / `scaleAmount` (empty / scalable / fixed over authored amount strings; exact-rational rewrite, `scaled` aliases `original` when empty/fixed/overflow) plus `scaleRecipe`, which calls `scaleAmount` on ingredient quantities only. Linear scaling by an exact rational factor, `.servings` mode reading the frontmatter `servings`/`serves`/`yield` key (leading number; default 1), **fixed** quantities (`@salt{=1%tsp}`) locked, timers and cookware never scaled, recipe references never touched (their quantities are directives for the referenced recipe), non-numeric quantities unchanged. Mixed `1 1/2` is a canonical scalable input (emits integer / fraction / terminating decimal, never mixed). Exact rational arithmetic (no f64): whole results emit integers, non-whole emit reduced fractions, decimal-family sources emit exact terminating decimals (≤ 12 digits). Frontmatter passes through raw/unmodified. `oliver scale --from cooklang (--factor num[/den] | --servings n)` CLI; `scale-basic`/`scale-servings`/`scale-mixed` fixture pairs. Docs/COOKLANG.md §11. |
| application features (filesystem reference resolution, shopping lists, pantry, aisles, images, search, meal scheduling, publication) | deferred | documented as ecosystem conventions (conventions.md), not language; consumers (e.g. Boris) own them. |

## Recorded ambiguities and chosen behaviors

1. **Textile line breaks.** Hobix prose says newlines become `<br />` but its
   rendered example shows a plain newline; Textile 2 explicitly says `<br />`
   (except the last line). **Oliver: `<br />` for every internal newline.**
2. **Block interruption without a blank line.** CommonMark explicitly allows
   ATX headings to interrupt paragraphs; the historical Textile references do
   not define every adjacency between marker lines and open blocks. **Oliver:
   recognized Textile marker lines (`hN.`, `p.`, `bq.`) always start a new
   block, even without a preceding blank line.**
3. **Marker whitespace.** Textile 2: signatures "end with a period and be
   followed with a space"; a third-party note (Mylyn/WikiText docs) says a
   line is only a heading if `hN.` is immediately followed by a space.
   **Oliver: a recognized `hN.`, `p.`, or `bq.` marker must be followed by a
   space or tab; all following separator whitespace is consumed.**
4. **Paragraph whitespace.** **Oliver: Textile paragraph content is preserved
   verbatim (only marker separator whitespace is consumed).** Markdown
   paragraphs are trimmed per line. The dialects genuinely differ; the model
   represents the resulting text identically.
5. **Inline modifier sets.** Hobix and Textile 2 disagree on the full inline
   set (`++`/`--` exist only in Textile 2). **Oliver implements each feature
   once, from the behavior the majority of references support, and documents
   the choice in this matrix.**
6. **Markdown ATX closing sequences.** `# foo # #` — the spec says a closing
   sequence is a trailing run of `#`s preceded by spaces/tabs. **Oliver
   applies a single pass: only the final run is a closing sequence, so the
   content is `foo #`.**
7. **Markdown tabs.** The spec expands tabs to 4-space tab stops where
   whitespace defines block structure. **Oliver implements the spec's tab
   stops: a tab advances to the next multiple of 4 columns for all block
   structure, while content bytes are never expanded. A tab partially
   consumed by a container's content indentation stays as the view's first
   byte, and its leftover columns become spaces in indented-code content
   (spec Tabs examples 4–7). Tabs after the opening `#` are ordinary
   separator whitespace (matches the spec's `#→Foo` example).**
8. **Markdown paragraph whitespace.** §4.8: "The paragraph's raw content is formed by concatenating the lines and removing initial and final spaces or tabs." Oliver (slice, chosen): leading spaces/tabs are skipped on every line; trailing whitespace is governed by the hard-break rule (two+ spaces → hard break, else soft break; the run is always consumed). With indented code blocks and tab stops implemented, the full §4.8 example set (including the indented-continuation and paragraph-interruption cases) conforms byte-for-byte.
9. **NUL replacement timing.** CommonMark mandates parse-time NUL → U+FFFD.
   **Oliver preserves NUL in the model and replaces at render time** so spans
   always reflect source bytes; output is identical.
10. **Terminal backslashes in headings.** Hard breaks separate inline content
    within a block and therefore do not occur at a block's end. Oliver keeps a
    terminal backslash literal in both ATX headings (example 646) and Setext
    heading content (example 90).
11. **Trailing tabs and hard breaks.** §6.7 requires "two or more spaces";
    Oliver counts only ASCII spaces in the trailing run (a tab does not
    trigger a hard break, but the whole run is consumed).
12. **Alt flattening of breaks and code spans.** §6.4 says only the plain
    string content of an image description is used, with no spec example
    for breaks or code spans inside a description. **Oliver: soft and hard
    breaks flatten to `\n`** (a break's plain string content is the line
    ending; the hard-break marker is consumed as usual) **and code spans
    flatten to their §6.1-normalized content.** Both pinned by fixtures
    (`image-alt-breaks`, `image-alt-code`); see docs/IMAGES-PARSING.md
    §3/§8.
13. **Historical section-number drift.** Some older design records cite
    images as §6.7. Canonical CommonMark 0.31.2 numbers Images as §6.4;
    current feature contracts and new work use the canonical numbering.
14. **Inactive `[` openers are kept, not cleared.** A formed link marks
    every earlier `[` inactive per the spec appendix, and an inactive `[`
    still intercepts a later `]` (it must not reach a `![` below it).
    Oliver implements this with a monotone O(1) check instead of
    re-marking, so the shape stays linear (fixture
    `image-inactive-bracket`; docs/IMAGES-PARSING.md §2).
15. **Reference-style images share the link reference machinery.** The
    appendix's *look for link or image* procedure is uniform for links
    and images, so `![alt][label]`/`![alt][]`/`![alt]` resolve through
    the same §4.7 definition table, label normalization (Unicode case
    fold + whitespace collapse), first-wins, and full→collapsed→shortcut
    ordering as reference links (docs/REFERENCE-IMAGES.md). A formed
    reference image inactivates nothing — the inactive rule keys on
    formed *links* only, matching the inline-image behavior. The
    description's bracket text is the collapsed/shortcut label; matching
    is on the raw bracket text (normalized), not the parsed description
    (`![*foo*][]` matches a definition labeled `*foo*` while the alt
    flattens to `foo`).
16. **Textile single-period block-quote termination.** The current Textile
    Markup Language Documentation says a block quotation ends with a blank
    line and distinguishes the multi-paragraph `bq..` form. The compact Hobix
    example does not spell out continuation-line termination. **Oliver:
    unmarked lines after `bq.` remain in its one quoted paragraph until a
    blank line or another recognized block signature.** `bq..` is a later,
    separately documented feature rather than an accidental synonym.
17. **Textile inline-code delimiter edges.** Hobix documents at-sign-delimited
    code phrases, and Textile 2 documents `@code@`, entity escaping, generic
    whitespace sensitivity, and bracket/brace forcing. Neither reference
    defines embedded at-signs, multiline matching, empty/edge-whitespace
    content, or a backslash escape. **Oliver: code is same-line and nonempty;
    operators touch non-whitespace content and have outside Unicode
    whitespace/punctuation-or-symbol boundaries; the first following `@` is
    the only closer candidate; invalid shapes remain literal; backslash is
    inert.** Bracket/brace forcing and `==...==` escaping are later features.
    See `docs/TEXTILE-INLINE-CODE.md`.
18. **Textile phrase operators share the `@code@` boundary contract.** Both
    references agree on the operator set and the doubling rule (`**` → bold,
    `__` → italic); neither defines nesting, run splitting, intraword
    enforcement, or mismatched-closer behavior. **Oliver: openers/closers use
    the same Unicode whitespace/punctuation boundaries as `@code@`; matching
    is strict LIFO by character and run length; phrase content is scanned for
    nested phrases;    runs longer than any documented operator (and unmatched
    openers) stay entirely literal; `++`/`--` big/small are implemented per
    the user's request (Textile 2's `<big>`/`<small>` — the only reference
    documenting them, see §17).**
    See docs/TEXTILE-PARITY.md §3.
19. **Textile link/image URL edges.** Both references require whitespace
    around a hyperlink and say common punctuation may follow; Textile 2
    documents the bracket/brace trick. Neither defines URL terminators or
    display-text formatting. **Oliver: the URL stops at whitespace or
    `)]}`; trailing sentence punctuation (`.`, `,`, `;`, `:`, `!`, `?`,
    quotes, `)]}`) is excluded; link display text and image src/alt are
    opaque plain text; the image `(alt)` doubles as title.**
    See docs/TEXTILE-PARITY.md §3.
20. **Textile list termination and item shape.** Both references show lists
    as marker-prefixed lines and nesting by marker count; neither defines
    multi-line items, lazy continuation, mixed markers at one depth, or
    depth jumps. **Oliver: items are single lines; lists are tight; a blank
    line, a block signature, or a non-marker line closes the tree; a
    different marker at the same depth starts a sibling list; a depth jump
    opens empty intermediate items.** See docs/TEXTILE-PARITY.md §3.
21. **The repo's own docs use GFM tables by choice.** The authoring docs
    (README.md plus ten `docs/*.md`: ARCHITECTURE, BLOCKS-PARSING,
    DOCUMENT-MODEL, ENTITIES, FEATURE-MATRIX, IMAGES-PARSING,
    INLINE-PARSING, TESTS, TEXTILE-PARITY, WORK-LEDGER) use GFM table
    syntax, which Oliver rendered literally until the tables extension
    landed. The docs are read on GitHub and in source, where GFM tables
    are the native format, and no Oliver consumer renders them (Oliver is
    markup infrastructure; static-site generation is a documented
    non-goal), so converting them to raw-HTML `<table>` blocks was never
    warranted. **Oliver: resolved — the GFM tables extension is now
    implemented (docs/TABLES.md is the contract doc), so the docs render
    correctly through Oliver too. The update points named here — the
    "tables (GFM extension)" row above, the DOCUMENT-MODEL.md convergence
    table, the fixture index, and the shared-model convergence pairs in
    tests/fixtures_test.zig — are all updated.**
