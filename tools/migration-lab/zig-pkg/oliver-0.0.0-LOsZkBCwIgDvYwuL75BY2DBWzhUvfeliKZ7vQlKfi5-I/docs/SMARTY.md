---
published_at: 2026-08-16T00:00:00Z
summary: Contract for the opt-in smartypants typography pass in the Markdown frontend — one shared implementation with Textile (shipped, issue #67).
---

# Smart typography (`smartypants`) — contract

**Status:** implemented — shipped via issue #67 (milestone v1.0, "The
Goodest Boy"); the provenance record is in docs/CLEANROOM.md session
27.  \
**Modules:** shared `src/typography.zig` (extracted from
`src/textile.zig`), `src/markdown.zig` (parse), `src/textile.zig`
(caller)  \
**Options:** `markdown.Options.smartypants: bool = false`

Textile already implements the legendary typotastic rules
(docs/TEXTILE-PARITY.md §13 — T15). This contract brings those **exact**
transform passes to CommonMark as an opt-in pipeline, as **one shared
implementation with two callers**: the machinery is extracted from
`src/textile.zig` (`replaceChars`, `hasCharMacroTrigger`, the
quote-direction helpers, the paren-symbol table) into a shared module,
Textile becomes a caller whose output stays **byte-identical** (the
Textile fixture wall is the regression net), and Markdown calls the same
pass on plain text when the option is on. No new upstream material is
consulted; the extraction and chosen scope are recorded in a new
clean-room session.

## 1. The replacement set (the Textile passes, verbatim)

| source | result | rule |
| --- | --- | --- |
| `"` `'` | curly quotes | direction by the surrounding source bytes: opening after start-of-content, whitespace, or `(`/`[`/`{`; otherwise closing; apostrophes by position |
| `--` | em dash (`—`) | a run of two hyphens |
| ` - ` (space-surrounded) | en dash (`–`) | single hyphen between spaces |
| `...` | ellipsis (`…`) | a run of three periods |
| digit-adjacent `x` | dimension sign (`×`) | `2 x 4`, `2x4` |
| `(c)` `(r)` `(tm)` | © ® ™ | case-insensitive |
| `(1/4)` `(1/2)` `(3/4)` | ¼ ½ ¾ | |
| `(o)` | ° | |
| `(+/-)` | ± | |
| `---`, `....` | `—` + `-`, `…` + `.` | runs of 3+ replaced left-to-right |

The Textile `{...}` character-macro table (T20) is **Textile-only**:
braces in CommonMark are ordinary text, and smartypants never enables
the macro table (pinned — `{c|}` stays literal under smartypants).

## 2. Where the pass applies

- Applied to plain `.text` nodes in every Markdown inline scope:
  paragraphs, ATX/Setext headings, list items, table cells (GFM), link
  **display text** (matching Textile, which replaces inside link text),
  footnote bodies, definition-list terms and definitions, and callout
  titles/bodies (pinned by `cross-smartypants-scopes`: a footnote body
  and a definition term both curl and dash). A heading containing a
  wikilink slugs on the label, and the non-ASCII replacement bytes are
  dropped by `slugify`, so heading ids are unaffected (also pinned by
  `cross-smartypants-scopes`).
- **Exempt (verbatim):** code spans, code blocks (fenced and indented),
  autolink labels, link destinations and titles, image src/alt/title,
  raw HTML and inline HTML, and HTML-looking `<...>` regions — the same
  exemption set Textile pins today (docs/TEXTILE-PARITY.md §13).
- Image alt strings are exempt: the description's text nodes do not pass
  through the typography pass when they flatten into `alt`.

## 3. CommonMark-specific pins

- **Link titles are exempt by construction:** title parsing runs before
  the text pass (`[x](url "title")`), so the quoted title is never
  curled.
- **Escaped characters stay straight:** a backslash-escaped `\"` or `\'`
  renders the literal straight character (the escape's output is literal
  punctuation, not typography) — the CommonMark parallel of Textile's
  `==...==` exemption.
- **No phrase interplay:** CommonMark has no `--smaller--` big/small
  phrase and no phrase operators, so `--` and `-` runs need no
  phrase-scanner coordination — a `--` always em-dashes under smartypants.
- **Borrow-or-copy contract:** untouched text borrows the source slice;
  only spans containing a replacement allocate arena copies — identical
  to the current `hasCharMacroTrigger`-first fast path.
- **Determinism:** the pass is a pure function of the source bytes and
  position; no hidden state.

## 4. Rendering and XHTML

- No renderer changes: replaced payloads flow through the existing text
  writer (the renderer already escapes and emits payloads — a
  backslash-escaped `\"` still renders `&quot;`, HTML-escaped like any
  text).
- No new elements; curly quotes, dashes, and symbols are valid in both
  output profiles. The XHTML well-formedness gate is unaffected
  (a dedicated case verifies both profiles).

## 5. Interaction with the other extensions

- `wikilinks`: wikilink targets/labels are exempt (plain-text payloads,
  not re-scanned — pinned: `[[Wiki -- Target]]` keeps its dashes) —
  matching the exemption set.
- `callouts`: the title and body are ordinary inline scopes; the pass
  applies there like anywhere else (pinned in `smartypants-scopes`).
- `front matter`: stripped before the body parses; never processed.

## 6. Acceptance and fixtures (shipped)

- `"Hello," -- she said...` → `“Hello,” — she said…` (byte-pinned);
  `2 x 4` → `2 × 4`; `(c)` → ©; apostrophes by position.
- Exemptions pinned: `` `code "quotes"` ``, fenced code, autolinks, raw
  HTML tags, link destinations/titles, image src/alt/title, escaped
  `\"`/`\'`, and the Textile-only `{...}` macro table (literal).
- Literal fallbacks pinned: `---` → `—` + `-`, `....`, `(1/3)`,
  letter-touching hyphens (no en dash in `foo-bar`), plain `x`.
- Fixture wall: `smartypants-basic` (the replacement set, runs, symbols),
  `smartypants-exempt` (the §2 exemption battery), `smartypants-scopes`
  (headings incl. the heading-id slug, link display text, list items,
  GFM table cells, callout title/body, wikilink exemption), plus the
  cross-extension `cross-smartypants-scopes` (footnote bodies,
  definition-list terms, heading slug on a wikilink) and
  `cross-callout-title` (wikilink + typography composing in a callout
  title).
- Textile fixtures byte-identical before/after the extraction refactor
  (the wall is the regression net).
- Off by default: quotes/dashes stay literal — 652/652 + full suite
  green.

## 7. Conformance status

Extension, off by default: the CommonMark 0.31.2 corpus is untouched
(re-verified at integration: 652/652 with the `--gate` harness, and the
Cooklang 60/60 gate). The fixture wall lives at
`tests/fixtures/markdown/smartypants-*`.
