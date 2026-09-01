---
published_at: 2026-08-14T00:00:00Z
summary: Contract for the raw HTML slice of Oliver's Markdown frontend (section 6.6): implemented.
---

# Oliver Inline Parsing: Raw HTML (§6.6)

**Status: implemented.** This document was written and committed before any
raw HTML code; it remains the contract for the raw HTML slice of Oliver's
Markdown frontend: inline
raw HTML tags (`<tag ...>`, `</tag>`, comments, processing
instructions, declarations, CDATA sections). It is derived entirely
from the CommonMark specification (0.31.2, §6.6 "Raw HTML" and §6.1's
precedence note) and Oliver's own docs; no other parser implementation
was consulted. The block-level HTML blocks (§4.6) are out of scope —
this slice is inline-only.

## 1. What the spec says

§6.6: text between `<` and `>` that looks like an HTML tag is parsed as
a raw HTML tag and rendered in HTML **without escaping**. Tag and
attribute names are not limited to current HTML tags (custom and
DocBook tags are legal). The grammar, verbatim from the spec:

- **tag name**: ASCII letter, then zero or more ASCII letters, digits, or `-`.
- **attribute**: spaces, tabs, and up to one line ending; an attribute
  name; an optional attribute value specification.
- **attribute name**: ASCII letter, `_`, or `:`; then ASCII letters,
  digits, `_`, `.`, `:`, `-`.
- **attribute value specification**: optional spaces, tabs, and up to
  one line ending; `=`; optional spaces, tabs, and up to one line
  ending; an attribute value.
- **attribute value**: unquoted (nonempty; no spaces, tabs, line
  endings, `"`, `'`, `=`, `<`, `>`, or `` ` ``), single-quoted
  (`'`...`'`), or double-quoted (`"`...`"`).
- **open tag**: `<` + tag name + zero or more attributes + optional
  spaces/tabs + up to one line ending + optional `/` + `>`.
- **closing tag**: `</` + tag name + optional spaces/tabs + up to one
  line ending + `>` (no attributes, no `/`).
- **HTML comment**: `<!-->` or `<!--->`, or `<!--` + (a string not
  containing `-->`) + `-->`.
- **processing instruction**: `<?` + (a string not containing `?>`) + `?>`.
- **declaration**: `<!` + ASCII letter + (no `>`) + `>`.
- **CDATA section**: `<![CDATA[` + (no `]]>`) + `]]>`.

Two consequences fall straight out of the grammar and drive the design:

1. **Tags span line endings.** Every whitespace chunk in the grammar
   allows "up to one line ending", and quoted attribute values, comments,
   PIs, declarations, and CDATA have *unbounded* content. So raw HTML
   tags are multi-line constructs, like code spans — they cannot be
   recognized per-line.
2. **Backslash escapes are inert inside tags.** A tag's bytes are
   consumed wholesale; `\<` never starts one, and `\*`/`\"` inside a tag
   are literal tag bytes (spec examples 19–20).

## 2. Precedence

§6.1: "Code spans, HTML tags, and autolinks have the same precedence."
Inlines are parsed sequentially left to right; at each position the
first construct that matches wins. §6.6's precedence note: "Backtick
code spans, autolinks, and raw HTML tags bind more tightly than the
brackets in link text" — so a `]` or `[` inside a tag never closes or
opens link text, and links/images bind more tightly than emphasis.

Oliver already implements this first-come rule with a two-phase
architecture: `discoverCodeSpans` finds code spans over the whole
paragraph, then `scanLine` walks left to right consuming the earliest
construct. Raw HTML slots into the same mechanism: a `discoverHtmlTags`
pass finds maximal tags over the whole paragraph, and `scanLine` merges
the two sorted lists by earliest start, dropping any construct that
starts inside an already-accepted one. The drop rule is exactly
first-come: `` `<a href="x">` `` is a code span (its `<` is inside the
span), `` `<a href="`">` `` is a tag (its backtick is inside the tag).

### Tag vs autolink at `<`

The two grammars are **mutually exclusive**, so their relative order at
a `<` is unobservable in practice:

- An autolink requires `:` immediately after the scheme (no whitespace).
- An open tag requires the character after the tag name to be
  whitespace, `/`, or `>` — never `:` (a `:` after the tag name can only
  begin an attribute name, and attributes require preceding whitespace).

So `<ab:cd>` is an autolink (the tag attempt fails at the `:`), and
`<ab :cd>` is a tag (the autolink attempt fails at the space). This
slice tries the tag first, then the autolink, and documents that the
order is moot by the grammars' mutual exclusion.

## 3. Model and renderer

- **Model**: one new leaf inline tag, `.raw_html` (`Data.none`). The
  node's `span` covers the whole tag (`<` through `>`), including any
  line endings inside it; like `data.text`, the renderer reads the bytes
  from the source by span — no arena copy, no normalization. The growth
  path's `raw_inline` placeholder is replaced by this tag.
- **Renderer**: writes `doc.src.bytes[node.span.start..node.span.end]`
  verbatim — no escaping. The ARCHITECTURE.md "raw-HTML policy
  (allowed / escaped / rejected)" knob stays a future `RenderOptions`
  extension; this slice implements the CommonMark behavior, *allowed*
  (verbatim), which is what the spec examples encode.
- **Alt flattening (chosen behavior, spec-silent)**: no spec example
  pins raw HTML inside an image description. Consistent with the other
  leaf inlines (code spans and autolinks contribute their content), a
  raw HTML node in a description contributes its **raw source bytes**
  to the `alt` string — `![<b>x</b>](u)` → `alt="<b>x</b>"`, rendered
  escaped. (The alternative — dropping the tag entirely, "all markup
  removed" — is recorded here as rejected; the leaf-inline reading is
  uniform with the model's other leaves.)
- **Breaks**: a line ending *inside* a tag is tag content, not a
  soft/hard break (spec hard-line-break example: `<a href="foo  \nbar">`
  keeps the newline and produces no `<br />`). Mirrors the existing
  `terminatorInsideConstruct` check suppresses breaks for both code spans and
  raw HTML tags.

## 4. Scanner design

`discoverHtmlTags(doc, contents, tags)` scans the whole paragraph byte
range (like `discoverCodeSpans`), skipping any `<` that is
backslash-escaped. At each unescaped `<` it tries, in order:

1. `<!--` → comment (`<!-->` and `<!--->` special forms, else scan for `-->`)
2. `<?` → PI (scan for `?>`)
3. `<![CDATA[` → CDATA (scan for `]]>`)
4. `<!` → declaration (ASCII letter, then scan for `>`)
5. `</` → closing tag (tag name, then whitespace incl. ≤1 line ending, then `>`)
6. `<` + ASCII letter → open tag (tag name; then a loop of
   whitespace+attribute pairs; optional `/` before `>`)
7. otherwise → not a tag (the `<` is left for the autolink attempt in
   `scanLine`)

Each whitespace chunk is `[ \t]* (line ending)? [ \t]*` — at most one
line ending per chunk; a second consecutive line ending fails the tag.
Line endings are `\n`, `\r\n`, and `\r` (the spec's definition, as
already used by `source.Line`). A successful match consumes the whole
tag (quoted values and comment/PI/CDATA content may run to the
paragraph end); a failure leaves everything from the `<` alone.

`scanLine` consumes the merged construct list. The cross-advance rule is:
when a code span is consumed, tags starting inside it are dropped; when a tag
is consumed, code spans starting inside it are dropped; a tag that opened on
an earlier line is skipped like a multi-line code span. The `<` branch sees a
pre-discovered tag first and, when no tag matched, falls through to the
existing autolink attempt.

## 5. Verification and test plan

1. Verify the §6.6 spec examples (Raw HTML section) byte-for-byte via
   the spec-conformance harness (`zig build spec-conformance -- spec.txt
   --section "Raw HTML"`). The fixture corpus below mirrors all 20 examples
   (the paired comment and backslash-attribute examples share fixtures), and
   the local fixture suite is green; the standalone scorecard still requires
   a locally fetched `spec.txt`.
2. Fixtures: `raw-*.md`/`.html` — open tags (simple, empty-element,
   whitespace incl. a line ending, attributes with quoted/unquoted
   values, custom tag names), closing tags, comments (`<!-->`,
   `<!--->`, multi-line with `--` inside), PI, declaration, CDATA,
   entity-in-attribute, backslash-in-attribute, the illegal shapes
   (tag names, attribute names/values, whitespace) staying literal,
   multi-line tags suppressing breaks, tags in emphasis/link text,
   image-alt flattening, and code-span/tag precedence pairs.
3. Unit tests: tag grammar edges (attribute loops, line-ending budget,
   `/` before `>`, closing-tag attribute rejection), comment/PI/
   declaration/CDATA spans, escape-inert `\<`, precedence with code
   spans and autolinks, multi-line tag spans, break suppression,
   model/renderer (verbatim bytes, no escaping), and flattenAlt.
4. Adversarial smoke: many `<` near-misses, deep attribute loops,
   unterminated quotes/comments running to the paragraph end, tags
   mixed with the existing bracket/delimiter/backtick workload — all
   linear (every scan is bounded and forward-only).
5. Quality gate: `zig fmt --check`, `zig build`, `zig build test`
   green; the whole pre-existing suite must pass unchanged; the Raw HTML
   fixture corpus must remain byte-exact.

## 6. Completion

The slice is implemented on the existing scan → match → emit seam. It adds
the `.raw_html` leaf to the document model, discovers all six CommonMark
construct forms across paragraph lines, resolves first-come precedence with
code spans, autolinks, and link brackets, renders source spans verbatim, and
uses the documented raw-source policy for image-alt flattening. Nineteen
fixture cases cover the 20 §6.6 examples, with focused unit tests for spans,
precedence, multiline break suppression, alt flattening, and renderer output.
The final local quality gate is 90/90 tests passing (84 library + 6 fixture
tests), plus clean formatting, build, and diff checks.
