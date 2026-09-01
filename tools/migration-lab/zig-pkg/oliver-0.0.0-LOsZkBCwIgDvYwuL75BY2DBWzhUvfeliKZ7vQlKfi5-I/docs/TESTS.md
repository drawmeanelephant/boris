---
published_at: 2026-08-13T00:00:00Z
summary: Tests are product contracts: zig build test runs five suites covering library modules, fixtures, conformance, CLI parsing, and the XHTML profile.
---

# Oliver tests and fixtures

Tests are product contracts. `zig build test` runs five suites (the
fifth — the XHTML profile suite — is described in its own section below):

1. **Library module tests** — 236 `test` blocks inside `src/*.zig` covering
   source lines/spans, the normalized document, diagnostics, both dialect
   frontends, the Cooklang frontend (parser + canonical serializer +
   pure scaling + the HTML policy + the `.menu` view), Unicode case
   folding, the HTML renderers, and the public API.
   Markdown tests pin the container stack, thematic-break/list precedence,
   multiline Setext transformation, reference-definition interaction,
   terminal-backslash behavior, fenced-code payload/spans, every implemented
   inline family, exact AST shapes, and exact spans. Textile tests pin
   `p.`/`hN.`/`bq.` structure, hard-break terminators, `@code@` payloads,
   the phrase-modifier family (tags, spans, nesting, boundary fallbacks),
   links (titles, bracket trick, literal fallbacks) and link aliases
   (document resolution, precedence, literal shapes, every inline
   context, a 2,000-definition storm), images (alt/title,
   link attachment, literal fallbacks), list structure/nesting/termination,
   table structure/spans/attributes (cell modifiers, colspan/rowspan,
   header-alignment propagation, signature and row modifiers, literal
   fallbacks, block closing, a 20,000-row storm, and GFM-model
   convergence), block attributes on `p.`/`hN.`/`bq.` signatures (class,
   id, style with `; ` normalization, lang, the four alignments, `(`/`)`
   padding, heading combinations, blockquote placement, and literal
   fallbacks), `bc.`/`pre.` code blocks (escaped vs verbatim content,
   multi-line collection, signature-shaped content lines, blank-line
   termination, modifier attrs, and literal fallbacks), `bq..`/`bc..`/
   `pre..` extended blocks (blank-line paragraph separation inside one
   blockquote, blank lines as code content, signature termination,
   modifiers, def-line interaction, and literal fallbacks), a
   10,000-pair phrase storm, and a 2,000-deep phrase-nesting workload.
   Renderer tests construct documents directly so renderer behavior is
   verified without a dialect parser.
2. **Fixture and adversarial tests** — 14 tests in `tests/fixtures_test.zig`.
   The explicit index contains 275 Markdown and 105 Textile fixture pairs.
   The Markdown wall includes byte-exact CommonMark 0.31.2 coverage of
   emphasis/strong, code spans, inline links, inline/reference-style images,
   block quotes, list items and lists (§§5.2–5.3: marker-width indentation,
   ordered starts and near misses, empty items, interruption, nesting,
   marker/delimiter separation, tight/loose propagation, and quote/list
   composition),   reference links, autolinks, raw HTML, thematic breaks,
   Setext headings, fenced and indented code blocks (§4.4 chunks,
   interruption, tab-stop indentation in markers/containers), tab-stop
   handling (§2.1), and GFM pipe tables (the normative §4.10 examples
   byte-for-byte plus alignment colons, escaped pipes including the
   `<code>|</code>` code-span form, container nesting, inline-parsed
   cells, padding/truncation, and literal non-table fallbacks;
   docs/TABLES.md); the Textile wall covers `bq.`
   quotes, `@code@` spans, the full phrase-modifier family
   (strong/emphasis/bold/italic/del/ins/sup/sub/span, big/small
   `++x++`/`--x--` with the em-dash interplay — a matched `--` pair is
   consumed as a delimiter while space-adjacent/intraword/numeric and
   unmatched `--` still em-dash — nesting, and literal
   boundary fallbacks), links (`"text":url`, titles, the bracket trick,
   literal fallbacks), images (`!url!`, alt/title forms, the `!url!:href`
   attachment, literal fallbacks), link aliases (`[alias]url` definitions
   with uses before or after, the Textile 2 definition-block form,
   first-wins/case-sensitive precedence, and literal fallback shapes),
   `*`/`#` lists with nesting,
   sibling-marker switches, and termination, and `|a|b|` tables
   (the Hobix examples byte-for-byte — simple, header cells, cell
   attributes, colspan, rowspan, cell style, signature on its own line,
   row attributes — plus the Textile 2 complex example, header-alignment
   propagation, inline cells, literal fallbacks, and block closing;
   docs/TEXTILE-PARITY.md §6), and block attributes
   (the Hobix §4 battery byte-for-byte — class, id, class#id, style with
   `; ` normalization, lang, the four alignments, `(`/`)` padding,
   combined `h2()>.`/`h3()>[no]{color:red}.` forms, `bq` attrs on the
   `<blockquote>`, heading attrs, and literal fallback shapes;
   docs/TEXTILE-PARITY.md §8), and `bc.`/`pre.` code blocks
   (escaped `<pre><code>` with signature-shaped content lines kept
   verbatim, verbatim `<pre>` preserving HTML, modifier attrs on the
   `<pre>`, and literal fallback shapes; docs/TEXTILE-PARITY.md §9), and
   `bq..`/`bc..`/`pre..` extended blocks (the Textile 2 example
   byte-for-byte, blank-line paragraph separation inside one
   blockquote, blank lines as verbatim code content, signature
   termination, and literal fallback shapes;
   docs/TEXTILE-PARITY.md §10),   and footnotes
   (the `[N]` reference → `<sup class="footnote"><a href="#fnN">N</a></sup>`
   and `fnN.` block → `<p class="footnote" id="fnN"><sup>N</sup> body</p>`
   forms, multiple footnotes in order, block modifiers on the signature,
   and literal fallback shapes; docs/TEXTILE-PARITY.md §11), and
   block-quote citations (the current docs' `bq.:URL` example
   byte-for-byte, cite + modifiers, trailing-punctuation trim, extended-
   block termination, and literal fallback shapes;
   docs/TEXTILE-PARITY.md §12), and character
   replacements (the Hobix battery byte-for-byte — curly quotes, em/en
   dashes, ellipsis, dimension sign, `(TM)`/`(R)`/`(C)` — plus the
   current docs' case-insensitive `(c)`/`(r)`/`(tm)`, fractions/degree/
   plus-minus, replacements inside phrases and link display text,
   verbatim exemptions for HTML-looking regions and `@code@`, and
   literal fallback shapes; docs/TEXTILE-PARITY.md §13), `==`
   escaping (the Textile 2 block-region example byte-for-byte — raw
   passthrough with blank lines inside, the delimiter interrupts
   paragraphs/lists/tables and open `bc.`/`bc..`/`bq..` blocks,
   unterminated and empty regions — plus the inline suspension form,
   literal fallback shapes, and opacity inside `@code@`/link/image
   payloads; docs/TEXTILE-PARITY.md §14), line
   attributes (the pipe form converging byte-identically with
   `p<mods>.`, extended-block termination, and literal fallback
   shapes; docs/TEXTILE-PARITY.md §15), and image
   modifiers (the six alignment operators, the size forms
   `10x20`/`10w 20h`/`20%x40%`/`20%`, style/class/id/padding, the
   linked-image combination, and literal fallback shapes;
   docs/TEXTILE-PARITY.md §16), span phrase
   attributes (`%[es]cabeza%` → `<span lang="es">` and the other
   Hobix forms, the combined fixed-order run, nested phrases, and
   literal fallbacks — malformed runs, whitespace/empty content, a
   `%` inside a style value; docs/TEXTILE-PARITY.md §18), the same
   phrase attributes on every other operator (`*{color:red}x*` →
   `<strong style="color:red;">`, `_(big)x_` → `<em class="big">`,
   the doubled/long operators, Hobix's example line byte-for-byte,
   and the shared fallbacks plus the em-dash interplay;
   docs/TEXTILE-PARITY.md §19), the citation operator
   (`??Cat's Cradle??` → `<cite>Cat’s Cradle</cite>` with the
   replacement, attrs + nesting, Hobix's example, the both-flag
   delimiter fix, and the family fallbacks;
   docs/TEXTILE-PARITY.md §20), the acronym form   (`CSS(Cascading Style Sheets)` → `<acronym title="…">`, the
   conservative shape contract, and opacity inside `@code@`/link
   display; docs/TEXTILE-PARITY.md §20), definition lists
   (   `dl. term:definition` → `<dl>`/`<dt>`/`<dd>` with multi-line
   definitions and hard breaks, `dl<mods>.` attrs, term phrases, the
   term-run rule, and the literal signature fallbacks;
   docs/TEXTILE-PARITY.md §21), the `clear.` marker (a lone
   `clear.`/`clear<.`/`clear>.` line parking a CSS fragment the next
   block folds ahead of its own style — across paragraphs, headings,
   and lists — plus the literal shapes and the dangling-marker drop;
   docs/TEXTILE-PARITY.md §22), the `notextile.`/`notextile..` raw
   block (the current-docs example byte-for-byte — `<em>` stays a
   real tag, `*Textilised*` stays literal — the single-period blank
   termination, the extended form's blank-line content through the
   next signature, CRLF preservation, and the literal lookalikes and
   empty-block drop; docs/TEXTILE-PARITY.md §23), and the
   `{...}` character macros (the documented table byte-for-byte with
   mirrored orders, inside link display text, the brace-edge rule
   that keeps `{*}`/`{-L}` whole, and the literal fallbacks;

   docs/TEXTILE-PARITY.md §18). Every Textile fixture family in the
   index is counted in the final coverage scorecard,
   docs/TEXTILE-PARITY.md §24 — one fixture pair per row, summing to the
   105 Textile pairs here. The Cooklang wall covers the semantic
   families end-to-end through Oliver's deterministic HTML policy
   (`cooklang-basic`, `cooklang-sections`, `cooklang-frontmatter`,
   `cooklang-literal`; docs/COOKLANG.md) and the canonical serializer
   round-trip pairs (`serialize-basic`, `serialize-literal` — input
   `.cook` → expected canonical `.cook`, pinning the fixed-point and
   literal/degraded round trips; docs/COOKLANG.md §10) and the scaling
   pairs (`scale-basic` factor 2, `scale-servings` via frontmatter
   servings, `scale-mixed` mixed `1 1/2` × 2 — input `.cook` → expected
   scaled canonical `.cook`; docs/COOKLANG.md §11) and the menu-view
   pair (`menu-basic`, the
   conventions' own Monday–Wednesday + dated-days example — input
   `.menu` → expected day/meal text dump; docs/COOKLANG.md §12) plus
   adversarial storms
   (huge marker/brace runs, thousands of adjacent ingredients, deep
   preparations, an unterminated block comment, 5,000 steps, a 100 KB
   single line) that must render twice to identical bytes. The suite also
   verifies shared-model convergence,
   hostile-input completion and leak freedom, NUL policy, diagnostics, and
   deterministic repeat rendering (list stress: 2k nested items, 10k
   same-marker items, 15k alternating markers, 12k variably indented
   markers, and 8k valid plus 8k near-miss ordered markers, each rendered
   twice).
3. **Conformance-harness tests** — 7 tests in `tools/spec_conformance.zig`:
   synthetic corpus extraction (CRLF, tab arrows), malformed-corpus
   rejection, official byte/example-count and SHA-256 identity checks,
   complete/nonoverlapping manifest validation, malformed divergence-record
   rejection, outcome classification, and the single-trailing-newline
   comparison. These tests need no downloaded corpus.
4. **CLI argument-parsing tests** — 10 tests in `src/main.zig`: pure
   `parseArgs` unit tests (no allocator, no I/O) pinning the subcommand
   grammar (exactly one of `render`/`serialize`/`scale`/`menu`), flag
   scoping (`--to` render-only; `--factor`/`--servings` scale-only),
   dialect validation, zero-factor/zero-servings rejection, and
   `--help`/`-h` handling. They run as part of the ordinary `zig build
   test` gate.

The current complete result is **280/280 tests passing** with Zig 0.16.0
(236 library module tests + 14 fixture/adversarial tests + 7
conformance-harness tests + 10 CLI argument-parsing tests + 13 XHTML
profile tests). On top of the unit gate: the CommonMark
0.31.2 corpus stays **652/652** with 0 mismatches (docs/README), the
Textile wall stays fully green, and the Cooklang canonical corpus passes
**60/60** via `zig build cooklang-conformance` (bare: the vendored
corpus `tests/cooklang/canonical.yaml` is the default — provenance in
docs/COOKLANG.md §2 — and the harness additionally asserts the
serializer's semantic fixed point over every corpus source).

## Fixture convention

Every fixture has exactly two files:

```text
tests/fixtures/<dialect>/<name>.<ext>   # input
tests/fixtures/<dialect>/<name>.html    # exact expected output
```

- `<ext>` is `.md` for Markdown, `.textile` for Textile, and `.cook` for
  Cooklang.
- Expected output is compared byte for byte. Generated block output ends in
  `\n`; raw HTML may preserve source line-ending bytes inside its span.
- Dialects have separate directories even when their normalized documents
  converge.
- Files are embedded at compile time with `@embedFile`, so fixture execution
  does not give the library core a filesystem dependency.
- `tests/fixtures_test.zig` is the explicit index. An unindexed pair is not a
  test and must not be treated as coverage.

To add a fixture:

1. Add the input and `.html` files.
2. Add one entry to the appropriate fixture table.
3. Run `zig build test --summary all`.

## Coverage requirements

A completed syntax feature should include, where meaningful:

- simplest valid form;
- nesting and interaction with already-landed syntax;
- ambiguous/precedence cases;
- malformed literal fallback;
- Unicode and line-ending cases;
- exact source-span assertions;
- byte-exact deterministic HTML;
- an adversarial shape capable of exposing accidental quadratic work.

The current Markdown wall covers emphasis/strong, code spans, inline and
reference links/images, definitions, autolinks, inline raw HTML, block quotes,
fenced code blocks, thematic breaks, Setext headings, escapes, breaks, paragraphs, and ATX
headings. The Textile wall covers the same families through the Textile
syntax plus the Textile-only phrase modifiers, links, images, and lists
(docs/TEXTILE-PARITY.md §5). The Cooklang wall covers every semantic
family (single-word and braced ingredients, integer/fraction/unit
quantities, fixed and absent quantities, preparations, text interleaving,
cookware, unnamed/named timers, multiple semantic items per step,
blank-line steps, forced line breaks, line/block comments, notes,
sections and their marker forms, recipe references, YAML front matter
boundaries, malformed delimiters, near misses that stay literal, empty
input, Unicode, CRLF/LF, NUL/malformed UTF-8, exact spans, and
structured diagnostics) — see src/cooklang.zig's 22 unit tests and the
60-test canonical corpus. The leaf-block slice adds four thematic-break fixture groups, eight
Setext groups, a terminal-backslash fixture, exact AST/span tests, renderer
profile tests, and a deterministic 10,000-cycle heading/break workload. The
fenced-code slice adds 13 fixture groups spanning the normative rule families,
exact normalized-payload/span tests, and direct container-boundary coverage.

## Direct document-to-HTML tests

`src/html.zig` builds documents with `Document.init`, `createNode`, and
`appendChild`, then asserts rendered bytes. These tests cover escaping, breaks,
heading clamping, list tightness, raw HTML, thematic breaks, code blocks, both void-element
styles, and empty documents independently of Markdown or Textile.

## Span contract

Spans are first-class behavior. Tests assert, among other things:

- an ATX heading covers its marker line;
- a Setext heading covers its content lines plus underline;
- a thematic break covers its marker line after container markers;
- a fenced code block covers its opening through closing fence while its
  payload contains only normalized literal content and trimmed,
  backslash-resolved info;
- inline children cover only emitted content bytes;
- line-break nodes cover the actual line terminator;
- stripped markers and consumed escape/delimiter bytes are not assigned to
  unrelated nodes.

## Adversarial wall

`tests/fixtures_test.zig` sends hostile bytes through parsing and rendering
under `std.testing.allocator`:

- 100 KB delimiter, backtick, bracket, backslash, and single-line runs;
- deep opener chains and mixed delimiter/code workloads;
- link/image component and unmatched-bracket storms;
- shortcut, collapsed, full, near-miss, and definition-map reference storms;
- very large labels;
- URI/email autolink matches and near misses;
- a 100,000-deep block-quote stack, lazy-continuation flood, and quote/blank
  alternation;
- mixed LF, CRLF, and CR plus NUL bytes;
- 10,000 repeated Setext/thematic transitions rendered twice and compared;
- a 20,000-level list/thematic near-miss that exercises linear suffix
  recognition;
- a 64-byte fence with 10,000 near closers and a 20,000-line unclosed literal
  block, each rendered twice.

The contract is completion without crash, leak, unbounded recursion, or output
nondeterminism. A dedicated fuzz target remains planned; the public
`parse(allocator, bytes, dialect, options)` API is already the fuzz entry point.

## CommonMark 0.31.2 scorecard

`tools/spec_conformance.zig` extracts every normative example from the
official CommonMark `spec.txt`, runs it through Oliver, and prints a per-section
scorecard. Normative examples are an allowed clean-room source.

```bash
curl -O https://spec.commonmark.org/0.31.2/spec.txt

zig build spec-conformance -- spec.txt
zig build spec-conformance -- spec.txt --section "Setext headings"
zig build spec-conformance -- spec.txt --gate
zig build spec-conformance-test
```

The harness is bound to the exact official 0.31.2 corpus (byte count,
example count, and SHA-256, recorded in `tools/commonmark_expectations.zig`)
and rejects a different file before running Oliver. Every example is
classified in a reviewed manifest (`docs/COMMONMARK-EXPECTATIONS.md`):
**supported** (must match byte-for-byte), **not-yet** (a new pass must be
reviewed, not silently counted), or a named **divergence** with pinned
Oliver output. The classified `--gate` fails on a supported regression, an
unexpected not-yet pass, or a changed divergence — in either direction. It
requires the complete corpus: `--section` is report-only and cannot be
combined with `--gate`. The harness converts the spec's tab-arrow marker to
a real tab and ignores exactly one renderer-owned final newline.

Current canonical baseline: **652/652 examples pass — full conformance**
(652 supported, 0 not-yet, 0 named divergences). The per-section table is
derived from the harness output and kept in sync with README.md:

| CommonMark 0.31.2 section | score |
| --- | --- |
| Tabs | 11/11 |
| Backslash escapes | 13/13 |
| Entity and numeric character references | 17/17 |
| Precedence | 1/1 |
| Thematic breaks | 19/19 |
| ATX headings | 18/18 |
| Setext headings | 27/27 |
| Indented code blocks | 12/12 |
| Fenced code blocks | 29/29 |
| HTML blocks | 44/44 |
| Link reference definitions | 27/27 |
| Paragraphs | 8/8 |
| Blank lines | 1/1 |
| Block quotes | 25/25 |
| List items | 48/48 |
| Lists | 26/26 |
| Inlines | 1/1 |
| Code spans | 22/22 |
| Emphasis and strong emphasis | 132/132 |
| Links | 90/90 |
| Images | 22/22 |
| Autolinks | 19/19 |
| Raw HTML | 20/20 |
| Hard line breaks | 15/15 |
| Soft line breaks | 2/2 |
| Textual content | 3/3 |
| **Total** | **652/652** |

The former ATX trailing-backslash divergence (example 646) was resolved to
the normative output by the thematic-break/Setext milestone; the last
not-yet example — §4.7 edge case #201, an angle destination directly
followed by a would-be title — was closed by the full-conformance
milestone. No named divergences remain. Failures are not silently skipped:
the classified gate makes the whole 0.31.2 corpus a regression wall.

## XHTML profile suite

`tests/xhtml_test.zig` (wired into `zig build test` alongside the
fixture wall) covers the `.xhtml` serializer profile end to end
(docs/XHTML.md):

- **Paired fixtures** — inputs with byte-exact `html` and `xhtml`
  expectations across Markdown, Textile, and Cooklang; pairs that are
  byte-identical document the shared serialization, and the Cooklang line
  break documents the one owned delta (`<br>` → `<br />`).
- **HTML-mode guard** — representative committed Markdown fixtures are
  re-rendered through the default profile and compared byte-for-byte to
  their committed `.html`, proving the new profile did not perturb HTML
  output.
- **Fail-closed raw content** — `.raw_html`, `.html_block`, and Textile
  `pre.` render in HTML mode and are rejected with
  `error.RawHtmlNotXmlWellFormed` under `.xhtml`.
- **Determinism** — repeated rendering under both profiles is
  byte-identical.
- **Well-formedness gate** — `tests/xhtml_wellformed.zig` is a small,
  hermetic, test-only XML well-formedness scanner (balanced,
  name-matched elements; quoted attributes; predefined + numeric
  entities; comments/CDATA/PIs; character validity). Representative
  Markdown, Textile, and Cooklang XHTML fragments are wrapped in a
  namespace-aware test-only wrapper and validated; the checker itself
  distinguishes clean from poisoned input.

## Commands

```bash
zig fmt --check build.zig build.zig.zon src tests tools
zig build test --summary all
zig build
```
