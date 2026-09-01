---
published_at: 2026-08-13T00:00:00Z
summary: The dependency-ordered engineering construction queue for Oliver at the CommonMark 0.31.2 leaf-block wave.
---

# Oliver engineering work ledger

This is the dependency-ordered construction queue at the CommonMark 0.31.2
leaf-block wave. It is an execution aid, not a promise that later cards will
land unchanged: current HEAD, specifications, tests, and discovered seams win.

## Traffic table

| lane | mission | semantic ownership | dependency / merge order | state |
| --- | --- | --- | --- | --- |
| lead | M1 thematic breaks + Setext headings | central Markdown block precedence; `document` thematic node; HTML leaf rendering | first | integrated on main (PR #10) |
| lead | M2 fenced code blocks | Markdown open-leaf state; shared code-block model; HTML rendering | stacked after M1 | integrated on main (PR #13) |
| conformance worker | Q1 list conformance wall | list fixture pairs and list-only hostile tests; no parser files | independent; merge after M1 only to minimize fixture-index conflict | integrated on main (PR #11) |
| Textile worker | T1 `p.`/break-span repairs + `bq.` | Textile frontend, Textile fixtures/provenance; no Markdown/core model | independent | integrated on main (PR #12) |
| lead | M4 §2.5 entities + HTML blocks types 6/7 | entity table + decode seams; `.html_block` leaf; info/dest/title normalization | after M3 | implemented on main (uncommitted) |
| lead | M5 HTML blocks types 1–5 | per-type terminator end conditions; type 1–6 paragraph interruption | after M4 | implemented on main (uncommitted) |
| lead | M6 full conformance | §4.7 angle-destination separator rule; manifest/pins to 652/652 | after M5 | implemented on main (uncommitted) |
| lead | M7 GFM tables extension | Markdown table open-leaf + header/delimiter/body parsing; `.table` family in model and HTML renderer; docs/TABLES.md contract | after M6 | integrated on main (PR #19) |
| Textile worker | T8 Textile tables | Textile `|a|b|` block rows, cell/row/table modifiers, header-alignment propagation, flat-row rendering; Textile fixtures; no Markdown/core changes | after M7 (reuses the `.table` model family) | integrated on main (PR #20) |
| Textile worker | T9 Textile link aliases | `[alias]url` definition lines + `"text":alias` references via a document-global alias table; Textile fixtures; no Markdown/core changes | after T8 | integrated on main (PR #21) |
| Textile worker | T10 Textile block attributes | `{style}`/`(class#id)`/`[lang]`/alignment/padding on `p.`/`hN.`/`bq.` signatures; block attrs in model + renderer; Textile fixtures; Markdown untouched | after T9 | integrated on main (PR #22) |
| Textile worker | T11 `bc.`/`pre.` block code | single-period code/preformatted leaf blocks owning verbatim lines until a blank line; `.code_block` verbatim `escape` flag + attrs; Textile fixtures; Markdown untouched | after T10 | integrated on main (PR #23) |
| Textile worker | T12 extended blocks (`bq..`/`bc..`/`pre..`) | double-period signatures stay active across blank lines: `bq..` flushes blank-line-separated paragraphs into one blockquote, `bc..`/`pre..` keep blank lines as code content; both end at the next block signature | after T11 | integrated on main (PR #24) |
| Textile worker | T13 Textile footnotes | `[N]` references → `.footnote_ref` sup links + `fnN.` blocks (paragraph attrs + leading sup); Textile fixtures; Markdown untouched | after T12 | integrated on main (PR #25) |
| Textile worker | T14 `bq.:URL` citations | citation URL after the block-quote period → the blockquote's `cite` attribute; block attrs combine; Textile fixtures; Markdown untouched | after T13 | integrated on main (PR #27) |
| Textile worker | T15 character replacements | curly quotes, em/en dashes, ellipsis, dimension sign, `(c)`/`(r)`/`(tm)`, fractions/degree/plus-minus applied to plain text in the inline pass; arena-owned replaced payloads; Textile fixtures; Markdown untouched | after T14 | integrated on main (PR #28) |
| Textile worker | T16 `==` escaping | lone `==` lines open a block-escape region emitted as a raw `.html_block`; inline `==...==` suspends formatting and replacements, emitting a literal `.text` node; Textile fixtures; Markdown untouched | after T15 | integrated on main (PR #31) |
| Textile worker | T17 line attributes | the `|mods|.` pipe form applies the §8 block-modifier set to the paragraph, byte-identical to `p<mods>.`; a `.line` modifier kind; Textile fixtures; Markdown untouched | after T16 | merged on main (PR #32) |
| Textile worker | T18 image modifiers | the documented image family — alignment (`!<x!`…`!~x!`), sizing (`10x20`, `10w 20h`, `20%x40%`, `20%`), `{style}`/`(class#id)`/padding — composes onto `.image.attrs`/width/height through the §8 machinery; shared model + renderer gain defaulted width/height/attrs; Markdown untouched | after T17 | merged on main (PR #33) |
| Textile worker | T19 big/small phrases | Textile 2's `++bigger++`/`--smaller--` → `<big>`/`<small>` slot into the phrase machinery as doubled `+`/`-` runs; a matched `--` pair is consumed (never em-dashed) while space-adjacent/intraword/numeric/unmatched `--` still em-dash; Tag gains big/small; Markdown untouched | after T18 | merged on main (PR #34) |
| Textile worker | T20 span attrs + `{...}` macros | `%{style}(class#id)[lang]x%` phrase attributes compose onto `.span` attrs (Hobix "Phrase Attributes"; malformed runs literal, empty-content runs fall back to a plain span, a `%` inside a style cannot close the span); Textile 2's documented `{...}` macro table with mirrored orders; the brace-edge phrase rule keeps `{*}`/`{-L}` whole for the macro pass; Markdown untouched | after T19 | merged on main (PR #35) |
| Textile worker | T21 phrase attributes on all operators | Hobix "Phrase Attributes" extended to the whole family: `*{color:red}x*` → `<strong style="color:red;">`, `_(big)x_` → `<em class="big">`, doubled/long operators included, via the shared `.phrase` payload + a combined renderer arm; same fallbacks as the span forms; a `{` after an opener is a style (macros only unattached); `--` em-dash interplay intact; Markdown untouched | after T20 | merged on main (PR #36) |
| Textile worker | T22 citation + acronyms | Hobix's `??citation??` → `<cite>` (a doubled `?` joins the phrase family with attrs + nesting) and `ABC(def)` → `<acronym title="def">`; the both-flag delimiter fix (a run that is open and close tries close first, then opens); the acronym whole-run skip keeps the scan linear; Markdown untouched | after T21 | merged on main (PR #37) |
| Textile worker | T23 dl. definition lists | Textile 2's `dl. term:definition` → `<dl>`/`<dt>`/`<dd>`, converging on the shared list model (a `.definition` kind + role-bearing `.list_item` payload); multi-line definitions, `dl<mods>.` attrs, the term-run rule, literal signature fallbacks; Markdown untouched | after T22 | merged on main (PR #38) |
| Textile worker | T24 clear. marker | Textile 2's lone `clear.`/`clear<.`/`clear>.` line parks a CSS fragment (`clear:both`/`left`/`right`) that the next block folds ahead of its own style via the §8 block-attribute machinery; applies to every block family, closes open extended blocks, literal lookalikes; Markdown untouched | after T23 | merged on main (PR #40) |
| Textile worker | T25 notextile. raw passthrough | the audit's last deferral: `notextile.`/`notextile..` (current Textile docs "No formatting"; Textile 2 uses `==` instead) opens a raw block emitted as one `.html_block` leaf — unformatted, unescaped, CRLF preserved — the signature form of the `==` escape; single-period blank termination, extended runs to the next signature, bare-marker blocks, literal lookalikes; Markdown untouched | after T24 | merged on main (PR #41) |
| Cooklang worker | CK1 Cooklang frontend | a first-class `*.cook` frontend: a typed Recipe model (blocks/steps/ingredients/cookware/timers/notes/sections/preps/recipe-refs/frontmatter) with exact spans, built from the official spec + EBNF + canonical corpus (pinned revision, MIT) under clean-room rules; canonical conformance harness; Oliver-owned tests; deterministic HTML policy; `--from cooklang` CLI; Markdown/Textile untouched | after the Textile audit (T1–T25) | merged (PR #43) |
| Cooklang worker | CK2 canonical serializer | `src/cooklang_serialize.zig`: semantic Recipe → valid `.cook`, deterministic and idempotent (canonical, not byte-identical round-tripping — docs/COOKLANG.md §10); front-matter passthrough; empty-front-matter parser fix (`---\n---` no longer panics); `oliver serialize --from cooklang` CLI; the conformance harness asserts the fixed point over every corpus source; serialize fixture pairs; Cooklang unit tests wired into `zig build test` (they had been skipped by lazy analysis); Cooklang gate added to CI; Markdown/Textile untouched | after CK1 (first stretch goal) | merged (PR #45) |
| Cooklang worker | CK3 pure scaling | `src/cooklang_scale.zig`: `scaleRecipe` derives a scaled Recipe — exact-rational linear scaling (no f64), `.servings` mode reading frontmatter `servings`/`serves`/`yield` (leading number, default 1), `=`-fixed quantities locked, timers/cookware/references never scaled, non-numeric unchanged, frontmatter untouched; `oliver scale --from cooklang (--factor | --servings)` CLI; 10 unit tests + 2 fixture pairs; per the conventions' "Scaling and Servings" (clean-room session 22); Markdown/Textile untouched | after CK2 (second stretch goal) | merged (PR #46) |
| Cooklang worker | CK4 richer HTML policy | `src/cooklang_html.zig` grows from the bare article/steps vocabulary into the richer generic policy: an **ingredients index** (one `<li>` per distinct ingredient — exact case-sensitive name, first occurrence's quantity/units/preparation, first-appearance order, recipe-ref items, cookware/timers excluded, omitted when empty), timers as `<time class="timer" datetime="PT25M">` (ISO-8601 duration for whole-number quantities with recognized day/hour/minute/second units, case-insensitive; named timers render `name (3 minutes)`), unnamed sections omit the empty `<h2>`, preparations surfaced in the index; 2 unit tests (ISO durations, richer-policy structure); the 4 HTML fixture pairs regenerated under the new vocabulary; Markdown/Textile untouched | after CK3 (third stretch goal) | merged (PR #47) |
| Cooklang worker | CK5 `.menu` view | `src/cooklang_menu.zig` — the explicit convenience layer: `.menu` files are valid Cooklang (no second parser), and `menuView` exposes the day/meal structure semantically (`Menu{ days }`, `Day{ name, date, references }`, `Reference{ path, quantity, units }`); trailing `(YYYY-MM-DD)` title dates (valid month/day), reference directives preserved as source text and never deduplicated/resolved, non-section top-level blocks ignored; `writeMenu` text dump shared by `oliver menu --from cooklang` and the `menu-basic` fixture (the conventions' own example); 6 unit tests; no meal-planning logic (shopping/scheduling/filesystem stay consumer-owned) | after CK4 (fourth stretch goal) | merged (PR #48) |
| serializer worker | X1 XHTML output profile | an explicit XML-compatible serializer profile over the existing renderers (docs/XHTML.md): `OutputProfile` (`html` default, `xhtml`) in `src/html.zig` and `src/cooklang_html.zig` — same IR, same semantics, different serialization bytes (voids always XML-form under `.xhtml`; Cooklang forced line breaks become `<br />`); fail-closed raw-content policy (`.raw_html`, `.html_block`, Textile `pre.` → `error.RawHtmlNotXmlWellFormed`, with an actionable CLI hint); `--to html|xhtml` on `render` (rejected on serialize/scale/menu), testable `parseArgs`; public `oliver.OutputProfile`; paired fixtures, HTML-mode guard against the committed fixture wall, determinism checks, and a hermetic test-only well-formedness gate (`tests/xhtml_wellformed.zig` + `tests/xhtml_test.zig`) wired into `zig build test`; CommonMark 652/652 and Cooklang 60/60 unchanged; docs (XHTML.md, ARCHITECTURE, README, TESTS, CAPABILITIES, COOKLANG, index/nav) | after the Textile audit (T1–T25) + Cooklang wave | PR in review |
| shared worker | F1 frontmatter extraction | `src/frontmatter.zig` sniff/strip pre-pass (YAML `---` / TOML `+++` at index 0) + documented bounded YAML/TOML subsets (docs/FRONTMATTER.md); `ParseResult.metadata` / `Recipe.metadata`; Cooklang `tryFrontmatter` convergence (raw/span contract intact); opt-in `ParseOptions.frontmatter` (default off — an index-0 `---` is today a §4.1 thematic break); out-of-subset payloads stay raw with a diagnostic; fixtures + docs; Markdown/Textile/Cooklang all receive the clean body | first of the extension wave (v0.5) | implemented on main (issue #66) |
| Markdown extension worker | E1 modular wikilinks | `Options.wikilinks` inline scan → `.wikilink` leaf (`target`/`label`) + resolver-aware render arm (default: target percent-encoded as the href, `label orelse target` as text; docs/WIKILINKS.md); Markdown fixtures; Textile and the CommonMark corpus untouched | after F1 (v0.5) | implemented on main (issue #64) |
| Markdown extension worker | E2 callouts/admonitions | `Options.callouts` recognition on the container-block quote path; `.block_quote` callout payload (`type`/`title`/`title_nodes`) + `<div class="callout callout-<type>">` render arm (docs/CALLOUTS.md); Markdown fixtures; corpus untouched | after E1 (v0.6) | implemented on main (issue #65) |
| shared worker | E3 smart typography | extract Textile's `replaceChars`/`hasCharMacroTrigger` machinery into one shared module (`src/typography.zig`; two callers, Textile byte-identical); `Options.smartypants` text pass with the Textile exemption set (docs/SMARTY.md); Markdown fixtures | after F1/E1 (v1.0) | implemented on main (issue #67) |
| Cooklang worker | CK6 string-quantity classify/scale + mixed numbers | public `classifyQuantity` / `parseFactor` / `scaleAmount` over authored amount strings (the exact-rational path, not `parseQuantity`'s f64 decimal arm); `scaleRecipe` becomes a caller of `scaleAmount` on ingredient quantities only; mixed `1 1/2` is a canonical scalable input (emits integer / fraction / terminating decimal); timers/cookware/refs still never scale; `scale-mixed` fixture; docs/COOKLANG.md §11 | after CK3 (issue #76; lets consumers delete a forked string scale) | this PR |

## M1 — Thematic-break / Setext precedence rung

- **Objective:** implement CommonMark §4.1 and §4.3 as one precedence slice.
- **Normative source:** CommonMark 0.31.2 examples 43–61 and 80–106,
  §4.7 definitions, §5 containers, appendix parsing strategy.
- **Dependencies:** landed container stack and paragraph/definition phase split.
- **Seams:** `src/markdown.zig`, `.thematic_break` in `src/document.zig`,
  `src/html.zig`, Markdown fixtures, architecture/model/test docs.
- **Acceptance:** Setext > thematic > list precedence; paragraph interruption;
  quote/list matched-vs-lazy behavior; multiline inline content; definitions
  before heading content; exact spans; both HTML void profiles; terminal
  paragraph backslash; no unexplained normative failures.
- **Tests:** 13 fixture pairs, AST/span unit tests, renderer test, deterministic
  10,000-cycle leaf storm, a 20,000-level thematic near-miss, and full
  suite/section scorecards.
- **Parallelism:** no. The lead owns this sensitive block-parser seam.
- **Integration:** first.
- **State:** integrated on main (PR #10). The canonical scorecard at this
  milestone was 513/652, thematic 18/19, Setext 25/27; the overall scorecard
  reached 546/652 after M2. Remaining focused failures require indented code.

## Q1 — List conformance wall

- **Objective:** turn the landed §5.2/§5.3 list behavior into byte-exact,
  provenance-labeled product tests and add list-specific hostile cases.
- **Normative source:** CommonMark 0.31.2 §§5.2–5.3 examples only.
- **Dependencies:** landed lists; no dependency on M1 semantics.
- **Seams:** `tests/fixtures/markdown/list-*`, fixture index, list-only
  adversarial tests. Parser/model/renderer edits forbidden.
- **Acceptance:** every included expected output is copied from the normative
  corpus and already passes; failures are reported rather than normalized away;
  nesting/marker/indent/ordered-boundary storms complete deterministically.
- **Tests:** 26 normative fixture pairs and named list stress/determinism test.
- **Parallelism:** yes; fixtures-only ownership.
- **Integration:** after M1 to resolve the shared fixture index once.
- **State:** integrated on main (PR #11); rebased onto the M1/M2 fixture index
  during integration.

## T1 — Textile single-period block quotes

- **Objective:** repair `p.` interruption and hard-break spans, then implement
  single-period `bq.` through the shared `.block_quote → .paragraph` IR.
- **Authoritative sources:** Hobix Textile Reference; Movable Type Textile 2
  Syntax; textile-lang.com block-quotation user documentation.
- **Dependencies:** existing shared block-quote model/renderer.
- **Seams:** `src/textile.zig`, Textile fixtures/index, Textile feature matrix
  and clean-room provenance. Markdown/core model/renderer edits forbidden.
- **Acceptance:** signatures interrupt; unmarked lines continue until blank or
  another signature; LF/CRLF/CR spans cover the preceding terminator; content
  spans exclude `bq.`; `bq..`, citations, and empty quotes remain deferred.
- **Tests:** eight fixture pairs, AST/span unit tests, 10,000-signature flood.
- **Parallelism:** yes; Textile-local ownership.
- **Integration:** independent after M1/Q1 fixture-index reconciliation.
- **State:** integrated on main (PR #12).

## M2 — Fenced code blocks

- **Objective:** implement CommonMark §4.5 fenced code as the next leaf block,
  including container composition and info strings.
- **Normative source:** CommonMark 0.31.2 §4.5 examples 119–147, §2.5 entities
  for info-string normalization (entity-dependent examples classified), and
  appendix phase-1 rules.
- **Dependencies:** M1 precedence rung. Requires a normalized `.code_block`
  node with content and optional info-string/language payload.
- **Seams:** lead-owned `document` tag/data contract, Markdown open
  leaf state, HTML `<pre><code>` rendering, fixtures/design docs.
- **Acceptance:** backtick/tilde run rules; closing fence length/indentation;
  unclosed-to-EOF; backticks forbidden in backtick info strings; content
  literal/opaque; matched quote/list behavior; exact spans; long-fence and
  unclosed-fence hostile cases.
- **Tests:** 13 fixture groups, canonical §4.5 wall, containers, CR/LF/CRLF,
  exact IR/rendering, fence-run and unclosed-content storms.
- **Parallelism:** no during core design/implementation; fixtures may be
  prepared independently after the model contract is fixed.
- **Integration:** after M1; before indented code.
- **State:** integrated on main (PR #13). Branch-state measurements: 113/113
  tests, canonical scorecard 546/652 and §4.5 at 28/29. The sole focused
  failure is the four-space-indented-code dependency.

## M3 — Tab-aware indentation and indented code

- **Objective:** implement CommonMark §2.2 tab stops and §4.4 indented code
  without corrupting source spans or container indentation.
- **Normative source:** CommonMark 0.31.2 Tabs examples 1–11, §4.4 examples
  107–118, §5 container indentation rules.
- **Dependencies:** M2 code-block IR. Requires an architectural design for a
  line cursor with virtual columns because partially consumed tabs cannot be
  represented by byte-slice advancement alone.
- **Expected seams:** `source`/Markdown line view, container matching,
  `.code_block`, renderer, all indentation-sensitive fixtures.
- **Acceptance:** four-column tab stops; paragraph non-interruption; blank-line
  retention; container/list code indentation; source spans remain byte-true;
  no quadratic indentation scanning.
- **Tests:** complete Tabs and Indented-code sections, mixed endings, nested
  lists/quotes, long whitespace/tabs.
- **Parallelism:** no until the virtual-column seam is designed by the lead.
- **Integration:** after M2.
- **State:** implemented on main. A `View` wraps each line with a
  tab-expanded column (the reference implementation's partially-consumed-tab
  model): container markers and block starts measure indentation in columns,
  partially consumed tabs stay as the view's first byte, and indented-code
  content strips four columns with the leftover of a straddled tab becoming
  spaces. Canonical scorecard 592/652; Tabs 11/11, Indented code 12/12,
  List items 48/48, Block quotes 25/25, Thematic/ATX/Setext/Fenced 100%.

## M4 — Entity references (§2.5) and HTML blocks types 6/7

- **Objective:** implement CommonMark §2.5 named + numeric character
  references everywhere the spec recognizes them, and the two HTML-block
  start kinds (§4.6 types 6/7) that the entity milestone's example #31 needs.
- **Normative source:** CommonMark 0.31.2 §2.5 examples 25–42, §4.6 examples
  155–178, and the WHATWG entities.json data source the spec names as
  authoritative (an HTML-specification data source, clean-room allowed).
- **Dependencies:** M3 tab/column work (HTML-block indentation ≤3 columns);
  the raw-HTML pass-through policy (docs/RAW-HTML.md); `.code_block` info
  payload (M2) for info-string normalization.
- **Expected seams:** new generated `src/entities.zig` (+ `tools/gen-entities.py`),
  entity-aware text writer in `src/html.zig`, `resolveEntities` in
  `src/markdown.zig`, `.html_block` leaf in `src/document.zig` + renderer,
  manifest/docs.
- **Acceptance:** named/numeric/hex decode with the §2.5 range rules; `;`
  required; recognized in text, destinations/titles, info strings, autolinks,
  and alt flattening but never in code spans/blocks and never as structural
  characters; backslash-escaped `&` never decodes; types 6/7 with blank-line
  end conditions and type-7 paragraph non-interruption.
- **Tests:** entity unit tests (generated with the table), text/rendering
  fixtures, HTML-block fixtures, updated escape/link fixtures, full suite.
- **Parallelism:** no (lead-owned seams: generated data, text writer, block pass).
- **Integration:** after M3.
- **State:** implemented on main (uncommitted). Canonical scorecard
  636/652, 0 regressions: Entities 17/17, HTML blocks 31/44 (types 6/7
  conform; the 13 not-yet examples need types 1–5), backslash escapes and
  links gain the incidental normalization passes. 138/138 tests green.

## M5 — HTML blocks types 1–5

- **Objective:** implement the remaining §4.6 HTML-block start kinds —
  type 1 (`<script|pre|style|textarea`, case-insensitive), type 2 (`<!--`),
  type 3 (`<?`), type 4 (`<!` + ASCII letter), type 5 (`<![CDATA[`) — with
  their per-type matching-terminator end conditions, closing the last
  HTML-block conformance gap.
- **Normative source:** CommonMark 0.31.2 §4.6 examples 155–178 (spec prose
  only; the terminator rules are fully specified there).
- **Dependencies:** M4's `.html_block` open-leaf machinery (start detection,
  container-stripped verbatim accumulation, blank-line end); the §4.6
  interruption rule, which types 1–6 satisfy (type 7 alone cannot interrupt).
- **Expected seams:** `HtmlBlock.block_type` + per-type end-condition scan in
  `src/markdown.zig`, type 1–5 start scanners, paragraph-laziness awareness
  (`isParagraphContinuationText`), manifest/docs.
- **Acceptance:** types 1–5 end at the first line containing their
  terminator (including a terminator on the start line itself, closing the
  block after one line) or a blank line; types 1–6 interrupt paragraphs,
  type 7 does not; content stays verbatim (no entity decode, no emphasis).
- **Tests:** unit tests for each start kind + end condition; fixture pairs
  `html-block-type1`…`type5`, `type1-raw`, `interrupt-types`; full suite.
- **Parallelism:** no (lead-owned seams).
- **Integration:** after M4.
- **State:** implemented on main (uncommitted). Canonical scorecard
  651/652, 0 regressions: HTML blocks 44/44, Lists 26/26 (the two
  `<!-- -->`-in-list examples, spec #308/#309, flip with type-2 support),
  and the sole remaining not-yet example is the §4.7 link-reference-
  definition edge case #201. 139/139 tests green.

## M6 — Full conformance (closing example 201)

- **Objective:** close the last not-yet example — §4.7 example 201,
  `[foo]: <bar>(baz)`. An angle-bracketed destination must be followed by
  spaces/tabs or the end of the line: with `(baz)` directly adjacent, the
  title has no separating whitespace, so the line is not a definition
  ("No further character may occur" after the destination, §4.7).
- **Normative source:** CommonMark 0.31.2 §4.7 example 201 and the
  definition grammar's whitespace-separator rule.
- **Dependencies:** M5's all-seven-HTML-block-types manifest.
- **Expected seams:** the angle-destination branch of
  `tryParseDefinition` (`src/markdown.zig`), manifest/pins, docs.
- **Acceptance:** `[foo]: <bar>(baz)` renders as literal text (`<p>[foo]:
  <bar>(baz)</p>`), not a definition; the bare-destination form (`[foo]:
  /url "title"`) is unaffected; gate reaches 652/652.
- **Tests:** the manifest partition test pins 652 supported / 0 not-yet;
  the whole corpus is the regression wall.
- **Parallelism:** no (lead-owned seams).
- **Integration:** after M5.
- **State:** implemented on main (uncommitted). Canonical scorecard
  **652/652 — full conformance**, 0 not-yet, 0 divergences, 0 regressions.
  140/140 tests green.

## T4 — Textile parity audit: phrase modifiers, links, images, lists

- **Objective:** build the Textile fixture audit (docs/TEXTILE-PARITY.md):
  inventory every implemented Textile feature against the shared document
  model, then close the biggest gaps vs. Textile 2 semantics — the inline
  phrase-modifier family, `"text":url` links, `!url!` images, and `*`/`#`
  lists.
- **Authoritative sources:** Hobix Textile Reference; Movable Type Textile 2
  Syntax (both clean-room allowed); the existing Textile contracts
  (docs/TEXTILE-INLINE-CODE.md).
- **Dependencies:** shared model/renderer; the T2 `@code@` boundary contract
  is reused uniformly for every inline family.
- **Seams:** `src/textile.zig` (inline item scan → LIFO phrase match → emit,
  plus the block-pass list tree), new shared tags `bold`/`italic`/`deleted`/
  `inserted`/`superscript`/`subscript`/`span` in `src/document.zig` and
  `src/html.zig`, Textile fixtures/index, feature matrix, model and parity
  docs. Markdown parser files untouched.
- **Acceptance:** the documented operator set renders to the documented HTML
  (`_x_`→`<em>`, `*x*`→`<strong>`, `**x**`→`<b>`, `__x__`→`<i>`, `-x-`→`<del>`,
  `+x+`→`<ins>`, `^x^`→`<sup>`, `~x~`→`<sub>`, `%x%`→`<span>`); nesting
  `*_way_*`; links with titles and the bracket trick; images with alt/title
  and the `!url!:href` attachment; tight single-line lists with marker-depth
  nesting; every ambiguous shape stays literal and is pinned by a fixture.
- **Tests:** 9 new unit tests (tags/spans, nesting, boundaries, links,
  images, lists, a 10,000-pair phrase storm, a 2,000-deep nesting workload)
  and 15 new Textile fixture pairs, plus shared-model convergence pairs.
- **Parallelism:** yes; Textile-local ownership, Markdown untouched.
- **Integration:** after M6 (the Markdown corpus is untouched, so the
  652/652 gate is unaffected).
- **State:** implemented on main (uncommitted). 148/148 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## M7 — GFM tables extension

- **Objective:** promote the "tables (GFM extension)" row from planned to
  implemented per recorded ambiguity 21 and issue #17: document the chosen
  syntax first, then implement GFM §4.10 pipe tables in the Markdown
  frontend.
- **Normative source:** GFM spec §4.10 (github.github.com/gfm,
  clean-room allowed); recorded ambiguity 21's update points.
- **Dependencies:** shared model/renderer; the phase-1 paragraph open-leaf
  and phase-2 single-line inline seams.
- **Seams:** new `.table`/`.table_row`/`.table_cell` tags in
  `src/document.zig` (alignment on the table, header/alignment on the
  cell), `<table><thead><tbody>` output in `src/html.zig`, the table
  open-leaf + delimiter-row conversion in `src/markdown.zig` (with the
  cell code-span pipe-escape post-fix), docs/TABLES.md, Markdown
  fixtures/index, feature matrix, model, test and ledger docs. Textile and
  the CommonMark corpus untouched.
- **Acceptance:** the normative §4.10 examples byte-for-byte (basic,
  alignment incl. the single-hyphen `:-:`, escaped pipes incl.
  `<code>|</code>`, break-at-blockquote, pipe-less body rows, mismatch
  stays a paragraph, pad/truncate, no-`<tbody>`); containers and
  inline-parsed cells (links/emphasis/code, reference links); non-table
  pipe lines stay paragraphs.
- **Tests:** 2 unit tests (node structure/alignment, escaped pipes +
  mismatch/literal fallbacks), a renderer-only table test, and 11 Markdown
  fixture pairs.
- **Parallelism:** yes; Markdown + model/renderer, Textile untouched.
- **Integration:** after M6 (corpus untouched; the 652/652 gate is
  re-verified).
- **State:** integrated on main (PR #19). 151/151 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T8 — Textile tables

- **Objective:** implement Textile's own `|a|b|` table syntax — the last
  large feature gap the parity audit recorded — converging with the
  `.table`/`.table_row`/`.table_cell` model family M7 introduced.
- **Authoritative sources:** Hobix Textile Reference "Tables" (rendered
  HTML examples); Movable Type Textile 2 Syntax "Tables" (modifier list,
  the `table(fig).` complex example, the header-alignment propagation
  rule, table-level `<`/`>`/`=` float/margin semantics); Textile Markup
  Language Documentation (modifier semantics). All clean-room allowed.
- **Seams:** `src/textile.zig` (table block state, row/signature
  recognition, the modifier scanner, close-time propagation), the model
  (`Attribute` lists on table/row/cell, `colspan`/`rowspan`, `justify`
  alignment, the `sections` flag), `src/html.zig` (attribute emission;
  `sections` selects flat rows vs GFM thead/tbody), Textile
  fixtures/index, feature matrix, parity/model/test/ledger docs. Markdown
  and the CommonMark corpus untouched.
- **Acceptance:** the Hobix table examples byte-for-byte (simple rows,
  header cells, cell attributes incl. `<`/`>`/`=`/`<>`/`^`/`~`, colspan,
  rowspan, cell style, `table{...}.` signature on its own line, row
  attributes); the Textile 2 complex example; header-alignment propagation;
  inline-parsed cells; literal fallbacks (no closing pipe, missing `. `
  terminator, `table. of contents`, unclosed braces); block closing;
  GFM-model structural convergence.
- **Tests:** 8 unit tests (structure/spans/rendering, cell modifiers and
  attrs, propagation + row headers, signature + row modifiers, literal
  fallbacks, block closing, a 20,000-row storm, GFM-model convergence),
  a renderer-only `sections` test, and 13 Textile fixture pairs.
- **Parallelism:** yes; Textile + model/renderer, Markdown untouched.
- **Integration:** after M7 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #20). 159/159 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T9 — Textile link aliases

- **Objective:** implement `[alias]url` definition lines and
  `"text":alias` references — the largest remaining documented Textile
  gap — converging with the Markdown §4.7 definition-table machinery.
- **Authoritative sources:** Hobix Textile Reference "External References:
  Link Aliases" (uses before the definition; the trailing-punctuation
  exclusion); Movable Type Textile 2 Syntax "Links" (definition blocks
  "anywhere within your document", multiple aliases per block). Both
  clean-room allowed.
- **Seams:** `src/textile.zig` (pass-1 alias collection over every line,
  the def-line recognizer, threading the alias table through the inline
  pass, alias lookup in `scanLink` with the href span carried on
  `LinkData`), Textile fixtures/index, feature matrix, parity
  (new §7), test and ledger docs, README. Markdown, model, and renderer
  untouched.
- **Acceptance:** the Hobix example (four references resolve, the def
  line vanishes, trailing `!` excluded); the Textile 2 definition-block
  form; first-definition-wins; case-sensitive exact matching; an
  undefined alias stays a relative URL; aliases resolve in headings,
  lists, and table cells; def lines vanish mid-paragraph without
  splitting it; literal fallback shapes.
- **Tests:** 4 unit tests (document resolution + the Hobix render, shapes
  and precedence, every inline context, a 2,000-definition storm), 4
  Textile fixture pairs, and 2 shared-model convergence pairs
  (`"x":alias` ↔ `[x][a]`, byte-identical).
- **Parallelism:** yes; Textile-local ownership, Markdown untouched.
- **Integration:** after T8 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #21). 163/163 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T10 — Textile block attributes

- **Objective:** implement the block attribute set (`{style}`,
  `(class#id)`, `[lang]`, `< > = <>` alignment, `(`/`)` padding) on `p.`,
  `hN.`, and `bq.` signatures — the last large documented block gap — so
  block signatures carry the modifier machinery the table and alias work
  already built.
- **Authoritative sources:** Hobix Textile Reference "Attributes: Block
  Attributes / Block Alignments" (class, id, class#id, style, lang, the
  four alignments, `(`/`)` indentation, and the combined `h2()>.` /
  `h3()>[no]{color:red}.` heading examples); Movable Type Textile 2
  Syntax "Block Attributes". Both clean-room allowed.
- **Seams:** `src/document.zig` (`.paragraph`/`.block_quote` gain attrs;
  `.heading` becomes `{ level, attrs }`), `src/html.zig` (attrs on the
  three block opens; `clampHeading` reads), `src/textile.zig` (a `.block`
  modifier kind in `scanMods`; `parseBlockSignature`; reworked
  `tryHeading`/`tryParagraphMarker`/`tryBlockQuoteMarker`; `emitHeading`
  carries attrs), Textile fixtures/index, feature matrix, parity (new
  §8), model/test/ledger docs, README. Markdown untouched.
- **Acceptance:** the Hobix §4 examples byte-for-byte (`p(example1).`,
  `p(#big-red).`, `p(example1#big-red2).`, `p{color:blue;margin:30px}.`
  with `; ` normalization, `p[fr].`, the four alignments, `p(.`/`p((.`/
  `p))).` padding, `h2()>.`, `h3()>[no]{color:red}.`); `bq` attrs land
  on the `<blockquote>` with the inner paragraph unmarked; malformed
  signatures (`p(foo not closed`, `p>.no-space`, `p..`, `bq..`, `bq:`,
  `h1x.`) stay literal; the 652/652 gate is untouched.
- **Tests:** 4 unit tests (paragraph attrs incl. `; ` normalization and
  id-only, alignment/padding/heading combinations, blockquote placement,
  literal fallbacks), 5 Textile fixture pairs (Hobix battery, combined
  forms, bq attrs, heading attrs, literal).
- **Parallelism:** yes; Textile + model/renderer, Markdown untouched.
- **Integration:** after T9 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #22). 167/167 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T11 — `bc.`/`pre.` block code

- **Objective:** implement the `bc.` block-code and `pre.` preformatted
  signatures — the last planned *block* family — converging with the
  Markdown `.code_block` model.
- **Authoritative sources:** Movable Type Textile 2 Syntax "Block
  Formatting" (`bc` is "block code": a preformatted section like `pre`
  that also gets a `<code>` tag, and "within a `bc` block, `<` and `>`
  are translated into HTML entities automatically"; "a block ends with
  the first blank line"); current Textile docs
  <https://textile-lang.com> (`pre.` "pre-formatted text", `bc.` "a
  block of lines of code"). Hobix documents neither signature (raw HTML
  only). Both clean-room allowed.
- **Seams:** `src/document.zig` (`.code_block` gains the verbatim
  `escape` flag and `attrs`), `src/html.zig` (the `pre.` verbatim branch
  and attrs on the `<pre>`), `src/textile.zig` (the `CodeSignature`/
  `CodeBlockState`/`tryCodeMarker`/`openCode`/`closeCode` leaf block
  owning verbatim lines until a blank line), Textile fixtures/index,
  feature matrix, parity (new §9), model/test/ledger docs, README.
  Markdown untouched.
- **Acceptance:** `bc.` escapes `<`/`>` inside `<pre><code>`
  byte-identically to a Markdown fence of the same content (convergence
  pair); `pre.` is verbatim `<pre>` preserving HTML; signature-shaped
  content lines stay code; the block ends at the first blank line and
  interrupts paragraphs/lists/tables; `bc{...}.`/`pre(...)[lang].`
  modifiers land on the `<pre>`; empty/near-miss/bare markers stay
  literal; the 652/652 gate is untouched.
- **Tests:** 2 unit tests (structure/content/span/modifiers; marker edge
  cases and block interaction), 4 Textile fixture pairs (bc basics, pre
  verbatim, attrs, literal), and 1 shared-model convergence pair
  (`bc.` ↔ fenced code, byte-identical).
- **Parallelism:** yes; Textile + model/renderer, Markdown untouched.
- **Integration:** after T10 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #23). 169/169 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T12 — Extended blocks (`bq..`/`bc..`/`pre..`)

- **Objective:** implement the double-period extended signatures that
  stay active across blank lines — the last documented block mechanism.
- **Authoritative sources:** Movable Type Textile 2 Syntax "Extended
  Blocks" ("To cause a given block signature to stay active, use two
  periods in your signature instead of one... until it hits the next
  signature is found", with the `bq..` example, and "especially useful
  for `bc` blocks where your code may have many blank lines scattered
  through it"); current Textile docs (extended blocks "are terminated
  with any other text block signature"). Both clean-room allowed.
- **Seams:** `src/textile.zig` (`ExtendedSig`/`tryExtendedMarker`,
  `openExtendedQuote` + `flushQuoteParagraph`, the `extended` flag on
  `ActiveBlock`/`CodeBlockState`/`CodeSignature`, `trySignature` as the
  terminator predicate, parse-loop ownership), Textile fixtures/index,
  feature matrix, parity (new §10), test/ledger docs, README. Model and
  renderer untouched (reuses `.block_quote`/`.code_block`).
- **Acceptance:** the Textile 2 `bq..` example byte-for-byte; blank-line
  paragraphs inside one blockquote; `bc..`/`pre..` keep blank lines as
  content; termination at any block signature (`p.`, `hN.`, `bq.`,
  `bc.`, `pre.`, `table`); list markers/table rows remain content; def
  lines vanish in `bq..` and stay code in `bc..`; empty `sig..`, `p..`,
  and `h1..` stay literal; single-period forms unchanged; the 652/652
  gate is untouched.
- **Tests:** 3 unit tests (extended quote structure/termination,
  extended code blank-line content, ownership/literal fallbacks), 4
  Textile fixture pairs, 1 shared-model convergence pair (`bc..` with
  blank lines ↔ fenced code), and the `bq-malformed`/`block-attr-literal`
  pins updated for the new contract.
- **Parallelism:** yes; Textile-local, Markdown untouched.
- **Integration:** after T11 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #24). 172/172 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T13 — Textile footnotes (`fnN.`/`[N]`)

- **Objective:** implement footnote references and blocks — `[N]` inline
  markers linking to `fnN.` paragraph blocks — the last documented
  inline↔block coupling.
- **Authoritative sources:** Hobix Textile Reference "Footnotes"
  ("footnote references are like this[1]... you begin a new paragraph
  with fn and the footnote's number, followed by a dot and a space",
  rendered example `[1]` → `<sup><a href="#fn1">1</a></sup>`); Movable
  Type Textile 2 Syntax "Footnotes" (same structure, adds
  `class="footnote"` on both the reference and the block). Both
  clean-room allowed. Oliver renders the Textile 2 (classed) form.
- **Seams:** `src/document.zig` (new `.footnote_ref` inline tag),
  `src/html.zig` (`<sup class="footnote"><a href="#fnN">N</a></sup>`
  open + close case), `src/textile.zig` (`FootnoteSig`/
  `tryFootnoteMarker` with the §8 modifier set, `scanFootnoteRef` in the
  inline scan pass, `footnote` fields on `ActiveBlock`, the sup prepend
  in `closeBlock`, `fnN.` in the extended-block terminator), Textile
  fixtures/index, feature matrix, parity (new §11), model/tests/ledger
  docs, README.
- **Acceptance:** the Hobix footnote example byte-for-byte with the
  Textile 2 classes; multiple footnotes in order; §8 modifiers on `fnN.`
  signatures (structural class/id first, user style/lang after); any
  digit run (`[12]`), numbers beyond `u16` stay literal; non-digit
  brackets, `[1x]`, empty signatures, and `fnx.` stay literal; `fnN.`
  terminates extended blocks; the 652/652 gate is untouched.
- **Tests:** 4 unit tests (block structure + sup span, inline refs,
  multi-digit, modifiers), 4 Textile fixture pairs, and the
  `link-alias-literal` pins updated for the new `[1]` contract.
- **Parallelism:** yes; Textile + one new shared inline tag, Markdown
  untouched.
- **Integration:** after T12 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #25). 175/175 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T14 — Block-quote citations (`bq.:URL`)

- **Objective:** implement the block-quote citation form — a citation
  URL immediately following the `bq` signature's period, rendered as
  the blockquote's `cite` attribute.
- **Authoritative sources:** current Textile Markup Language
  Documentation "Block quotations"
  <https://textile-lang.com/doc/block-quotations> — "Block quotes may
  include a citation URL immediately following the period:
  `bq.:http://textpattern.com/ A cited quotation.`" — plus Learn X in
  Y Minutes <https://learnxinyminutes.com/textile/> ("You can include
  a citation URL immediately after the '.'"). Neither Hobix nor
  Textile 2 documents the form; the current docs are already an
  allowed reference, and the rendering (the `cite` attribute) is the
  standard HTML blockquote citation, per the user's specification.
  Clean-room allowed.
- **Seams:** `src/document.zig` (`.block_quote` payload gains the
  arena-owned `cite`), `src/html.zig` (cite attribute on the
  blockquote open, via the href policy `writeEscapedHref`),
  `src/textile.zig` (`BlockQuoteSig` + `scanCiteUrl` URL run with the
  inline-link trailing-punctuation trim, the reworked
  `tryBlockQuoteMarker` returning the cite, `ActiveBlock.cite`
  threaded through `appendBlockContent`/`closeBlock`), Textile
  fixtures/index (incl. the `bq-malformed` and empty-signature pins
  updated for the new contract), feature matrix, parity (new §12),
  model/tests/ledger docs, README.
- **Acceptance:** the textile-lang example byte-for-byte; the §8
  modifiers combine (cite first, then attrs); trailing punctuation is
  trimmed from the URL with the separator check on the raw run;
  `bq.:` with no URL, a space after the colon, no content, no
  separator, or `bq..:URL` stays literal; a citation signature
  terminates an open extended quote; the 652/652 gate is untouched.
- **Tests:** 4 unit tests (structure + rendered output, trailing-
  punctuation trim, modifiers, literal shapes), 4 Textile fixture
  pairs, and the `bq-malformed` fixture/empty-signature unit-test
  pins updated for the new contract.
- **Parallelism:** yes; Textile + one model field, Markdown untouched.
- **Integration:** after T13 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #27). 179/179 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T15 — Character replacements

- **Objective:** implement the implicit typography the references
  document — curly quotes, em/en dashes, ellipsis, dimension sign,
  and the parenthesized symbols — applied to plain text only.
- **Authoritative sources:** Hobix "Entities" (curly quotes, `--` →
  em dash, ` - ` → en dash, `...` → ellipsis, `x` → dimension sign,
  `(TM)`/`(R)`/`(C)`); Movable Type Textile 2 "Character
  Replacements" (`(c)`/`(r)`/`(tm)`, `--` → em dash); current Textile
  docs "Automatic conversions" (quotes, dashes, ellipsis, dimension
  sign, `(tm)`/`(R)`/`(C)`, `(1/4)`/`(1/2)`/`(3/4)`, `(o)`, `(+/-)`).
  All three clean-room allowed.
- **Seams:** `src/textile.zig` (`replaceChars` + `hasCharMacroTrigger`
  fast path + helpers on the borrow-or-copy contract of the Markdown
  entity resolver, applied in `emitText` and the link display node),
  Textile fixtures/index (incl. the `special-chars`, `phrase-
  modifiers`, `phrase-boundaries`, `link-literal`, `link-alias-basic`,
  and `extended-bq` pins updated for the new contract), feature
  matrix, parity (new §13), model/tests/ledger docs, README. Model
  and renderer untouched.
- **Acceptance:** the Hobix battery byte-for-byte; the current docs'
  paren macros; apostrophes by position; replacements inside phrase
  content and link display text; `@code@`, code blocks, link/image
  src/alt/title, and HTML-looking `<...>` regions exempt; literal
  fallbacks (`---`, `....`, `(1/3)`, `(cd)`, letter-touching hyphens,
  plain `x`); the 652/652 gate is untouched.
- **Tests:** 4 unit tests (documented symbols, paren macros +
  apostrophes, exemptions/literal shapes, link display text), 3
  Textile fixture pairs, and 6 pre-existing pins updated for the new
  contract (curly quotes now reach prose; `--smaller--` renders as
  em-dashed text since `<small>` stays deferred).
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T14 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #28). 183/183 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T16 — Textile `==` escaping

- **Objective:** implement Textile 2's `==` escaping — the last
  documented inline/block mechanism — for both the block region and the
  inline span.
- **Normative source:** Textile 2 "Escaping" (a lone `==` line opens a
  region whose content is "not formatted by Textile at all", for
  dropping regular HTML into the document; inline `==...==` "temporarily
  disabl[es] the inline formatting functions"); the current Textile
  docs' special-characters page (the inline form suspends the character
  conversions: `Straight quotation marks are =="left alone"== in this
  example.`). Hobix does not document `==`; the other two references
  agree on the shape. Clean-room record in docs/CLEANROOM.md session 11.
- **Dependencies:** the `.html_block` leaf (M4/M5) and the character-
  replacement pass (T15) — the escape is exempt from it.
- **Seams:** `src/textile.zig` only; the shared model and renderer are
  untouched (block escape reuses `.html_block`, inline escape emits a
  plain `.text` node).
- **Acceptance:** the Textile 2 block example byte-for-byte; the current
  docs' quote example byte-for-byte; raw HTML passthrough with blank
  lines inside; the delimiter interrupts paragraphs, lists, tables, and
  open `bc.`/`bc..`/`bq..` blocks; unterminated and empty regions;
  literal fallbacks (`a==x==b`, `==x==y`, `===x==`, unmatched `==`);
  opacity inside `@code@`, link display text, and image src/alt;
  escaped spans never merge with neighbors (invariant 11); the 652/652
  gate is untouched.
- **Tests:** 3 unit tests (inline suspension + span/merge exactness,
  literal fallbacks + two escapes on one line, block regions),
  4 Textile fixture pairs (`escape-inline`, `escape-block`,
  `escape-block-html`, `escape-literal`).
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T15 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #31). 186/186 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T17 — Textile line attributes (`|mods|.`)

- **Objective:** implement the `|...|.` line-level attribute syntax — a
  pipe-delimited variant of the §8 block attributes — converging with
  the block-attribute machinery.
- **Normative source:** the user's specification. Clean-room finding
  (docs/CLEANROOM.md session 12): the pipe-attribute form is not in the
  three references — Textile 2's only pipe-delimited block parameter is
  the `|filter|` filter form — so the *pipe wrapping* is per-spec while
  every modifier and its composition is the reference-documented §8
  set. Supplementary user-facing sources checked: the original textism
  reference, the RedCloth reference manual, learnxinyminutes, the
  php-textile docs.
- **Dependencies:** the §8 block-attribute machinery (T10), extended
  blocks (T12), tables (T8) — the form must not collide with row syntax.
- **Seams:** `src/textile.zig` only (a `.line` modifier kind terminating
  at `|`, `tryLineAttr`, the parse-loop and `trySignature` wiring); the
  shared model and renderer are untouched — the attrs land on
  `.paragraph.attrs`.
- **Acceptance:** byte-identical output to the `p<mods>.` marker for the
  same modifier run; the full §8 set (style/class/id/lang, alignment,
  padding) composes in the pinned order; the form interrupts paragraphs,
  closes list trees, and terminates extended blocks; it never collides
  with table rows; literal fallbacks for every malformed shape; the
  652/652 gate is untouched.
- **Tests:** 2 unit tests (attribute-list convergence with `p<mods>.`,
  the literal battery + extended-block termination), 2 Textile fixture
  pairs (`line-attr-basic`, `line-attr-literal`).
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T16 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #32). 188/188 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T18 — Textile image modifiers

- **Objective:** implement the deferred image-modifier milestone —
  alignment, sizing (`10x20`, `10w 20h`, `20%x40%`, `20%`), and
  style/class/padding on Textile images — converging with the image
  model.
- **Normative source:** Textile 2 "Images" (the alignment operators,
  the size forms, the `{style}`/`(class)` set) and the current Textile
  docs "Images" page (`=` centering, the `(class)` form). Both
  references agree on the family; no parser implementation consulted
  (docs/CLEANROOM.md session 13).
- **Dependencies:** the §8 modifier machinery (T10), the `composeStyle`/
  `composeAttrs` composition, the shared `.image` leaf (T4).
- **Seams:** `src/document.zig` + `src/html.zig` (the `.image` payload
  gains defaulted `width`/`height`/`attrs`; the renderer writes them in
  the fixed order src, alt, title, width, height, attrs) and
  `src/textile.zig` (`ImageMods`, `scanImageMods`, `scanImageSize`, the
  `scanImage` rewrite, the emit composition). Markdown images never set
  the new fields, so Markdown output is byte-identical.
- **Acceptance:** the six alignment fragments (`float:left`/`right`,
  centered block, `vertical-align:middle`/`top`/`bottom`), last-align-
  wins; the four size forms parse and render as `width`/`height`
  attributes; size and alt never combine; style/class/id/padding compose
  in the pinned order; the linked-image form combines with modifiers;
  every malformed shape (bad modifier, junk post-src token, malformed
  size) stays literal; the 652/652 gate is untouched.
- **Tests:** 2 unit tests (modifier composition + size parsing,
  literal fallbacks), 2 new Textile fixture pairs (`image-mods-basic`,
  `image-mods-attrs`) plus the updated `image-literal` pin (Hobix's own
  `!>obake.gif!` aligned form).
- **Parallelism:** yes; the model/renderer additions are defaulted, so
  Markdown is untouched.
- **Integration:** after T17 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #33). 189/189 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T19 — Textile big/small phrases (`++x++` / `--x--`)

- **Objective:** implement Textile 2's `++bigger++`/`--smaller--`
  (big/small) phrase operators with the literal-run fallbacks the phrase
  family already pins — the last phrase-family gap.
- **Normative source:** Textile 2 "Inline Formatting" — "`++bigger++`
  Translates into `<big>bigger</big>`" and "`--smaller--` Translates
  into: `<small>smaller</small>`". The only clean-room reference carrying
  them (Hobix and the current docs do not); the earlier deferral followed
  the majority rule and the user's explicit request lifts it
  (docs/CLEANROOM.md session 14).
- **Dependencies:** the phrase machinery (T4) — a doubled run of `-`/`+`
  is a phrase operator like `**`/`__` — and the character-replacement
  em-dash rule (T15), whose interaction the milestone pins.
- **Seams:** `src/document.zig` + `src/html.zig` (`Tag` gains `.big`/
  `.small`, rendered `<big>`/`<small>`) and `src/textile.zig` only
  (`phraseOpFor` maps `-`/`+` runs of 2). Markdown never produces the
  tags, so Markdown output is byte-identical.
- **Acceptance:** the Textile 2 examples byte-for-byte; nesting
  (`++*big*++`); single-length del/ins unchanged; runs of 3+ stay
  entirely literal; a matched `--` pair is consumed as a delimiter while
  space-adjacent/intraword/numeric/unmatched `--` still em-dash through
  the replacement pass; opacity inside `@code@`; the 652/652 gate is
  untouched.
- **Tests:** 2 unit tests (Textile 2 examples + spans, nesting,
  over-long runs, em-dash interplay), 1 new Textile fixture pair
  (`phrase-big-small`) plus the `phrase-boundaries` over-long-run pin
  update.
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T18 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #34). 190/190 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T20 — Span phrase attributes + `{...}` character macros

- **Objective:** implement the attribute-bearing span forms
  (`%{style}(class#id)[lang]x%`, the span row's planned deferral) and
  the deferred `{...}` character-macro table.
- **Normative source:** Hobix "Phrase Attributes" — "all block
  attributes can be applied to phrases as well by placing them just
  inside the opening modifier" (`%[es]cabeza%` → `<span lang="es">`)
  — and Textile 2 "Inline Formatting" (the inline modifier list:
  style, lang, class/id) for the span; Textile 2 "Character
  Replacements" for the macro table ("all macros are enclosed in
  curly braces"; the nine documented forms with their mirrored
  orders). The general letter+accent pattern beyond the documented
  examples stays deferred (clean-room).
- **Dependencies:** the block-attribute machinery (T10), the phrase
  machinery (T4), the character-replacement pass (T15).
- **Seams:** `src/document.zig` + `src/html.zig` (`.span` gains an
  `attrs` payload, rendered in the fixed order) and `src/textile.zig`
  (SpanMods + scanSpanMods, the `%`-opener modifier run in the scan
  with an opaque skip, the emit composition with the plain-span
  fallback, the brace-edge phrase rule, and the macro table in
  replaceChars). Markdown never produces span tags — byte-identical.
- **Acceptance:** the Hobix span examples byte-for-byte; the fixed
  render order for a combined run; malformed runs literal; a `%`
  inside a style value cannot close the span; empty-content runs fall
  back to a plain span; the nine macro forms + mirrors; brace-adjacent
  phrase operators not recognized (`{*}`/`{-L}` stay whole); macros
  inside phrases and link display text, never in `@code@`/`==`; the
  652/652 gate is untouched.
- **Tests:** 3 unit tests (span attrs + spans, the fallbacks, the
  macro table), 4 new Textile fixture pairs (`span-attr-basic`,
  `span-attr-literal`, `char-macro-basic`, `char-macro-literal`).
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T19 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #35). 193/193 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T21 — Phrase attributes on every operator

- **Objective:** extend the T20 span-attribute machinery to the other
  phrase operators, implementing Hobix's `*{color:red}x*` and
  `_(big)x_` forms — the recorded T20 deferral.
- **Normative source:** Hobix "Phrase Attributes" — "all block
  attributes can be applied to phrases as well by placing them just
  inside the opening modifier", with the examples
  `*{color:red}blushed*` → `<strong style="color:red;">blushed</strong>`,
  `_(big)sprouted_` → `<em class="big">sprouted</em>`, and
  `%[es]cabeza%` → `<span lang="es">cabeza</span>` — the same
  Textile 2 inline modifier list (style, lang, class/id) as T20.
- **Dependencies:** the T20 span-attribute machinery (SpanMods +
  scanSpanMods, the opaque run skip, the emit composition), the
  block-attribute machinery (T10), the phrase machinery (T4), the
  character-replacement pass (T15).
- **Seams:** `src/document.zig` + `src/html.zig` (a shared `.phrase`
  payload for non-span phrase tags; the ten phrase-tag renderer cases
  collapse into one combined arm writing attrs; Markdown phrase nodes
  keep `.none` and render without attrs) and `src/textile.zig` (the
  scan's modifier gate drops its `%`-only condition, the opaque skip
  generalizes, the emit composes `.phrase` attrs for any phrase tag
  with a run).
- **Acceptance:** Hobix's example line byte-for-byte; every operator
  single, doubled (`**{...}x**`, `--{...}x--`), and long (`^[fr]x^`,
  `~[de]x~`) composes onto its own tag; the same fallback contract as
  the span forms (malformed run literal, whitespace-after not an
  opener, empty-content falls back to a plain phrase with the run
  bytes); an operator char inside a style value cannot close the
  phrase; `--` em-dash interplay intact; a `{` directly after an
  opener is a style token (the `*{c|}bold*` macro pin becomes a style
  pin; the `char-macro-literal` fixture keeps a genuine survival
  case); the 652/652 gate is untouched.
- **Tests:** 2 unit tests (model attrs + spans + Hobix's line, the
  fallbacks), 2 new Textile fixture pairs (`phrase-attr-basic`,
  `phrase-attr-literal`) plus the `char-macro-literal` pin update.
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T20 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #36). 195/195 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T22 — Citation operator + acronyms

- **Objective:** close the last two inline deferrals — Hobix's
  `??citation??` and the `ABC(def)` acronym form.
- **Normative source:** Hobix "Footnote-like citation" ("Use double
  question marks to indicate citation", `??Cat's Cradle?? by
  Vonnegut` → `<cite>Cat’s Cradle</cite>`) and Hobix "Acronyms"
  ("Definitions for acronyms can be provided by following an acronym
  with its definition in parens", `CSS(Cascading Style Sheets)` →
  `<acronym title="Cascading Style Sheets">CSS</acronym>`). Neither
  appears in Textile 2 or the current docs — the FEATURE-MATRIX
  "Hobix only" reading holds.
- **Dependencies:** the phrase machinery (T4) + the T21 phrase-attribute
  generalization, the boundary contract, the character-replacement
  pass (T15).
- **Seams:** `src/document.zig` + `src/html.zig` (`.cite` joins the
  phrase family; `.acronym` is a leaf with the letters + the
  definition title) and `src/textile.zig` (a doubled `?` run in
  phraseOpFor, the acronym scan with its whole-run skip, the emit
  case, and the both-flag delimiter fix in matchPhrases).
- **Acceptance:** Hobix's examples byte-for-byte; `??` accepts the
  phrase-attribute run and nests; lone `?`/3+-runs/malformed-runs
  literal; `I(think)`/`xCSS(no)`/`CSS()`/`CSS(open` literal while
  `US(...)`/`(CSS(...))` work; the definition is the opaque title;
  `@code@`/link display stay opaque; the both-flag fix lets
  `??_(big)x_??` and `(_(big)x_)` nest; the 652/652 gate is
  untouched.
- **Tests:** 2 unit tests (citation model/attrs/fallbacks; acronym
  model/fallbacks), 4 new Textile fixture pairs (`citation-basic`,
  `citation-literal`, `acronym-basic`, `acronym-literal`).
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T21 (the 652/652 gate is re-verified).
- **State:** integrated on main (PR #37). 197/197 tests green;
  canonical scorecard still 652/652 with 0 not-yet and 0 divergences.

## T23 — Definition lists (`dl.`)

- **Objective:** close the audit's last block-level deferral — Textile
  2's `dl. term:definition` definition list.
- **Normative source:** Textile 2 "Definition lists" — `dl.
  textile:a cloth, especially one manufactured by weaving` with the
  multi-line continuation and the note "there is no space between the
  term and definition. The term must be at the start of the line (or
  following the 'dl' signature as shown above)". The current Textile
  docs document a different dash-marker grammar (`- term :=
  definition`) — recorded, not implemented (clean-room session 18).
- **Dependencies:** the shared `.list`/`.list_item` model (Markdown
  §5.2/§5.3), the block-signature machinery (T10), the inline pass.
- **Seams:** `src/document.zig` + `src/html.zig` (`ListKind` gains
  `.definition`, `Data.list_item` carries the term/definition role,
  the `<dl>`/`<dt>`/`<dd>` rendering; Markdown list items keep
  `.none`) and `src/textile.zig` (`tryDefListSignature` +
  `tryDefItemAt`, the `DefListState` open/append/seal/close
  lifecycle, parse-loop wiring, and `trySignature` coverage).
- **Acceptance:** Textile 2's example byte-for-byte; multi-line
  definitions with hard breaks; `dl<mods>.` attrs on the `<dl>`;
  colon-in-def and term phrases; the term-run rule (a spaced `see
  also:` line continues the definition); termination at blank
  lines/signatures/`[alias]url`/EOF; `dl. plain text`, `dl. term:`,
  and `dl. ` literal; the 652/652 gate is untouched.
- **Tests:** 2 unit tests (model convergence + render, the literal
  fallbacks + continuation rules), 2 new Textile fixture pairs
  (`dl-basic`, `dl-literal`).
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T22 (the 652/652 gate is re-verified).
- **State:** merged on main (PR #38). 199/199 tests green; canonical
  scorecard still 652/652 with 0 not-yet and 0 divergences.

## T24 — `clear.` marker

- **Objective:** close the audit's `clear` deferral — Textile 2's `clear.`
  block signature that makes the next block emit a CSS style attribute
  clearing floating elements.
- **Normative source:** Textile 2 "clear" — `clear.` (clear both),
  `clear<.` (clear left), `clear>.` (clear right); "the next block should
  emit a CSS style attribute that clears any floating elements". The
  current Textile docs do not document the form (clean-room session 19).
- **Dependencies:** the §8 block-attribute machinery (T10) and the
  signature/family open sites in the parse loop.
- **Seams:** `src/textile.zig` (`tryClearMarker`, `mergeClearStyle` —
  the clear becomes the first style rule, prepended ahead of an existing
  style — and `takeClear` consumed at every block-open site in the parse
  loop via a `pending_clear` state; `trySignature` coverage). No model or
  renderer change: the fragment rides the existing attribute lists.
- **Acceptance:** `clear.` + plain paragraph → `<p style="clear:both;">`;
  `clear<.`/`clear>.` → `left`/`right`; merge ahead of `p{color:red}.`;
  applies to headings, block quotes (cite first), lists, tables,
  definition lists, footnotes, and code blocks; a marker closes an open
  extended `bq..`/`bc..`/`pre..` and definition list; inside a
  single-period `bc.` the marker is code content; a `[alias]url` def line
  between marker and block does not consume it; lookalikes
  (`clear. with content`, `clear x.`, `clearb.`) and a dangling marker
  at EOF stay literal/drop silently; the 652/652 gate is untouched.
- **Tests:** 2 unit tests (the fold across families + interaction with
  open blocks; the literal shapes and dangling-marker drop), 2 new
  Textile fixture pairs (`clear-basic`, `clear-literal`).
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T23 (the 652/652 gate is re-verified).
- **State:** merged on main (PR #40). 201/201 tests green; canonical
  scorecard still 652/652 with 0 not-yet and 0 divergences.

## T25 — `notextile.` raw passthrough

- **Objective:** close the audit's last deferral — the `notextile.`/
  `notextile..` block form that skips Textile processing entirely.
- **Normative source:** current Textile Markup Language Documentation
  "No formatting (override Textile)" — "For blocks of elements add a
  notextile. or notextile.. at the start of the block", with the example
  `notextile. This line <em>will not</em> be *Textilised*.` (the `<em>`
  stays a real tag, `*Textilised*` stays literal). Textile 2 does not
  document the form — its Escaping section presents `==` as the way to
  "let you put some regular HTML markup in your document" — recorded in
  clean-room session 20.
- **Dependencies:** the block-level `==` escape machinery (T16): the raw
  block is the signature form of the same `.html_block` payload.
- **Seams:** `src/textile.zig` only — `tryNoTextileMarker` (the
  single/double-period contract, bare markers allowed),
  `RawBlockState` + `openRawBlock`/`appendRawLine`/`closeRawBlock` (the
  contiguous-source-slice `.html_block` emission, CRLF preserved), the
  parse-loop wiring (a raw-owns branch next to the code branch, the
  blank-line handling for both forms, the marker branch, `trySignature`
  coverage, and the escape-delimiter/clear/EOF close points). No model
  or renderer change.
- **Acceptance:** the current-docs example byte-for-byte; bare-marker
  blocks; CRLF preserved; single-period ends at the first blank line;
  extended keeps blank lines and runs to the next block signature;
  `==` interrupts an open raw block; `notextile.` inside a single `bc.`
  is code content; closes open extended `bq..`/dlist; a pending
  `clear.` is dropped (no attribute list to land on); unterminated at
  EOF renders; lookalikes (`notextiles.`, `notextile.extra`, missing
  period, mid-paragraph) and empty blocks stay literal/nothing; the
  652/652 gate is untouched.
- **Tests:** 2 unit tests (the block contract + interactions; the
  literal shapes and empty-block drop), 2 new Textile fixture pairs
  (`notextile-basic`, `notextile-literal`).
- **Parallelism:** yes; Textile-only, Markdown untouched.
- **Integration:** after T24 (the 652/652 gate is re-verified).
- **State:** merged on main (PR #41). 203/203 tests green; canonical
  scorecard still 652/652 with 0 not-yet and 0 divergences. The wrap-up
  pass that followed (TEXTILE-PARITY §24) re-verified every matrix row
  against the live renderer, corrected the fixture count to 275 Markdown
  / 105 Textile pairs, and closed the audit with a coverage scorecard —
  the deferral pile is empty.## CK1 — Cooklang frontend

- **Objective:** add Cooklang as a first-class Oliver frontend: bytes → a
  typed Recipe semantic model with exact source spans and structured
  diagnostics, plus a deterministic HTML rendering policy and CLI
  access, without touching Markdown/Textile (gate stays 652/652).
- **Normative sources:** the official Cooklang specification
  (https://cooklang.org/docs/spec/), the `cooklang/spec` repository at
  commit `6c4788644004e604ae1da110af6d2400e3c9c7b0` (EBNF — marked
  WIP/outdated — conventions, released proposals 0005/0006, the
  canonical test corpus `tests/canonical.yaml` version 7, examples),
  all MIT. Full provenance and the chosen-behavior record in
  docs/CLEANROOM.md session 21 and docs/COOKLANG.md.
- **Dependencies:** `src/source.zig` spans, `src/diagnostic.zig`,
  arena ownership, `unicode.isWhitespace` + a new P-only punctuation
  predicate, `source.Lines`. No filesystem/network/global state in the
  parser.
- **Seams:** `src/cooklang.zig` (typed Recipe model + parser),
  `src/cooklang_html.zig` (Oliver-owned HTML policy),
  `tools/cooklang_conformance.zig` (canonical wall),
  `tests/fixtures/cooklang/`, `src/unicode.zig` (P-only predicate),
  `src/main.zig` (`--from cooklang`), `build.zig`
  (`cooklang-conformance` step), public API `oliver.cooklang.parse`.
- **Acceptance:** the full canonical corpus passes; every semantic
  family has Oliver-owned unit/fixture/adversarial tests; malformed
  input degrades to text deterministically (no crash/hang, no
  pathological rescans); the 652/652 CommonMark gate and the Textile
  suite stay green; docs (README, ARCHITECTURE, FEATURE-MATRIX,
  DOCUMENT-MODEL/COOKLANG, TESTS, CLEANROOM, WORK-LEDGER, CLI)
  describe the resulting capability.
- **Tests:** canonical conformance wall (60 tests), Oliver-owned unit
  tests per family, fixture pairs, adversarial/resource tests,
  deterministic repeat-render checks.
- **Parallelism:** no (touchpoints: unicode.zig, oliver.zig, main.zig,
  build.zig, fixtures_test.zig, docs).
- **Integration:** after the Textile audit; the CommonMark gate is
  re-verified at every commit.
- **State:** merged on main (PR #43). 206/206 tests green; Cooklang
  canonical conformance 60/60; CommonMark gate still 652/652 with 0
  mismatches; Textile suite untouched. Parser (typed Recipe: steps,
  ingredients, cookware, timers, notes, sections, preparations, recipe
  references, frontmatter boundary), structured diagnostics (four
  warning codes, literal-fallback policy), conformance harness, 4
  fixture pairs + adversarial storms, deterministic HTML policy, and
  `--from cooklang` CLI all landed. Remaining stretch goals recorded
  in docs/COOKLANG.md §9.

## CK2 — Canonical Cooklang serializer

- **Objective:** first stretch goal — turn the semantic `Recipe` back
  into valid `.cook` deterministically, with round-trip fixtures and a
  docs section distinguishing canonical serialization from
  byte-identical source round-tripping.
- **Normative sources:** none new — the serializer is Oliver-owned
  policy derived from the CK1 model and the spec's accepted syntax
  (docs/COOKLANG.md §10); no new upstream material consulted.
- **Dependencies:** `src/cooklang.zig` model only; the serializer
  allocates nothing (writer-only) and has no filesystem/network/global
  state.
- **Seams:** `src/cooklang_serialize.zig` (new), `src/main.zig`
  (`serialize --from cooklang`), `src/oliver.zig` (export + test
  wiring), `tools/cooklang_conformance.zig` (round-trip phase),
  `tests/fixtures/cooklang/serialize-*.cook` (pairs),
  `tests/fixtures_test.zig`, `.github/workflows/ci.yml` (Cooklang
  gate), and a parser fix in `src/cooklang.zig` (empty front matter).
- **Acceptance:** `serialize(serialize(x))` byte-identical;
  `parse(serialize(parse(x)))` semantically identical to `parse(x)`;
  every corpus source stable under the fixed point; front matter
  verbatim; `@x{}` vs `@x` distinct; literal/degraded shapes
  round-trip unchanged; empty front matter no longer panics.
- **Tests:** 2 serializer unit tests (round-trip fixed point over 18
  shapes incl. empty front matter; canonical spellings), 2 fixture
  pairs, and the harness round-trip phase over the 60-test corpus.
- **Parallelism:** yes; Markdown/Textile untouched; parser change is a
  narrow fix in `tryFrontmatter` (adjacent fences → empty payload).
- **Integration:** after CK1; the 652/652 gate is re-verified.
- **State:** merged on main (PR #45). 231/231 tests green (212 lib —
  now including the Cooklang parser/serializer unit tests, which lazy
  analysis had been skipping — + 12 fixtures + 7 harness); Cooklang
  canonical conformance 60/60 with the round-trip phase clean;
  CommonMark gate still 652/652 with 0 mismatches; Textile suite
  untouched; Cooklang conformance gate added to CI.

## CK3 — Pure Cooklang scaling

- **Objective:** second stretch goal — a pure `scaleRecipe()` semantic
  operation on the Recipe model, preserving fixed quantities and
  leaving referenced recipes untouched, per the conventions' "Scaling
  and Servings" section.
- **Normative sources:** the official Cooklang conventions
  (https://cooklang.org/docs/conventions/, "Scaling and Servings",
  fetched 2026-08-13) — conventions material (source-hierarchy level
  5); the language spec defines no scaling. Provenance and chosen
  behaviors in docs/CLEANROOM.md session 22.
- **Dependencies:** `src/cooklang.zig` model + `parseQuantity` (now
  public) + the serializer for the emission path. No filesystem,
  network, or global state; the input recipe is never mutated.
- **Seams:** `src/cooklang_scale.zig` (new: `scaleRecipe`, `ScaleBy`
  factor/servings, exact rationals, terminating-decimal formatting),
  `src/main.zig` (`scale --from cooklang --factor num[/den] |
  --servings n`), `src/oliver.zig` (export + test wiring),
  `tests/fixtures/cooklang/scale-*.cook` (pairs), `tests/fixtures_test.zig`.
- **Acceptance:** linear scaling of ingredient quantities; `=`-fixed
  quantities locked; timers/cookware/references/non-numeric unchanged;
  servings mode reads frontmatter `servings`/`serves`/`yield`
  (leading number, default 1); exact arithmetic (whole → integer,
  fractions reduced, decimal family → exact terminating decimal when
  den is 2^a·5^b, else fraction); invalid factors rejected; scaled
  output re-parses with consistent numeric views.
- **Tests:** 10 unit tests (families, exactness, servings metadata,
  invalid factors, sections/notes, empty inputs) + 2 fixture pairs
  (`scale-basic` factor 2, `scale-servings` via frontmatter) with
  fixed-point stability.
- **Parallelism:** yes; Markdown/Textile untouched; `parseQuantity`
  change is visibility-only.
- **Integration:** after CK2; the 652/652 gate is re-verified.
- **State:** merged on main (PR #46). 242/242 tests green (222 lib + 13
  fixtures + 7 harness); Cooklang conformance 60/60; CommonMark gate
  still 652/652 with 0 mismatches; Textile suite untouched.

## CK4 — Richer generic HTML policy

- **Objective:** third stretch goal — expand the Cooklang HTML policy
  into a richer generic recipe renderer with an ingredients index,
  section-aware layout, and preparation/timer semantics.
- **Normative sources:** none new — the HTML vocabulary is Oliver-owned
  policy (the spec defines no HTML); the index/timer semantics derive
  from the existing Recipe model and documented contract
  (docs/COOKLANG.md §7). No upstream material consulted.
- **Dependencies:** `src/cooklang.zig` model only (`parseQuantity` for
  the timer-duration whole-number rule); the renderer already writes to
  any writer and never reparses.
- **Seams:** `src/cooklang_html.zig` (ingredients index with
  StringHashMap dedup + first-appearance ordering, `<time>`/`datetime`
  ISO-8601 durations, unnamed-section `<h2>` omission, named-timer
  `name (3 minutes)` text), `src/oliver.zig` (forced analysis now
  includes cooklang_html so its unit tests run under `zig build test`),
  the 4 HTML fixture pairs (regenerated under the new vocabulary).
- **Acceptance:** every ingredient/reference appears once in the index
  in first-appearance order with first-occurrence quantity/units/prep;
  recipe references are index items and never resolved; cookware and
  timers never appear in the index; whole-number timers with recognized
  day/hour/minute/second units get ISO-8601 `datetime` (case-insensitive,
  abbreviations included); fractional/unknown-unit timers keep
  `data-quantity`/`data-units` only; unnamed sections render no empty
  `<h2>`; the index is omitted when empty; escaping and the data
  contract are unchanged.
- **Tests:** 2 unit tests (ISO-8601 duration mapping incl. null cases;
  richer-policy structure — dedup, refs, quantity/prep spans, `<time>`
  output, section headings) + the 4 fixture pairs pinned byte-for-byte.
- **Parallelism:** yes; Markdown/Textile untouched; the fixture HTML is
  Oliver's own policy and changes deliberately with the vocabulary.
- **Integration:** after CK3; the 652/652 gate is re-verified.
- **State:** merged on main (PR #47). 244/244 tests green (224 lib + 13
  fixtures + 7 harness); Cooklang conformance 60/60; CommonMark gate
  still 652/652 with 0 mismatches; Textile suite untouched.

## CK5 — `.menu` convenience view

- **Objective:** fourth stretch goal — an explicit `.menu` profile
  convenience API that parses menu files through the Cooklang frontend
  and exposes the day/meal structure semantically.
- **Normative sources:** the official conventions' "Menu Files" section
  and its example menu (https://cooklang.org/docs/conventions/,
  fetched 2026-08-13) plus the already-pinned section and
  recipe-reference semantics from the spec and corpus. Provenance in
  docs/CLEANROOM.md session 23.
- **Dependencies:** `src/cooklang.zig` model only — `.menu` files are
  valid Cooklang, so there is no second parser; the view is pure
  interpretation (no filesystem/network/global state; paths stay
  unresolved).
- **Seams:** `src/cooklang_menu.zig` (new: `menuView`, `writeMenu`,
  conservative `(YYYY-MM-DD)` title-date parsing, per-day reference
  collection), `src/main.zig` (`menu --from cooklang`),
  `src/oliver.zig` (export + test wiring), the `menu-basic` fixture
  pair, `tests/fixtures_test.zig`.
- **Acceptance:** every top-level section becomes a day in order with
  an optional ISO date and its recipe references (path + quantity +
  units as source text); invalid/trailing dates stay names; refs never
  deduplicated or resolved; non-section top-level blocks ignored; the
  text dump matches the conventions example byte-for-byte.
- **Tests:** 6 unit tests (days/dates, directives, conservative date
  parsing, top-level ignores, empty/reference-less inputs, the
  conventions example) + the `menu-basic` fixture pair with
  deterministic-repeat checks.
- **Parallelism:** yes; Markdown/Textile untouched.
- **Integration:** after CK4; the 652/652 gate is re-verified.
- **State:** merged on main (PR #48). 251/251 tests green (230 lib +
  14 fixtures + 7 harness); Cooklang conformance 60/60; CommonMark
  gate still 652/652 with 0 mismatches; Textile suite untouched. All
  four stretch goals are now banked; docs/COOKLANG.md §9's deferral
  list holds only conventions application features.

## C1 — Classified conformance expectations

- **Objective:** bind the conformance harness to the exact 0.31.2 corpus and classify each example as supported, not-yet-implemented, or a named Oliver divergence.
- **Normative source:** official CommonMark 0.31.2 `spec.txt` and its license.
- **Dependencies:** none; keep parser semantics out of scope.
- **Expected seams:** `tools/spec_conformance.zig`, versioned expectation data,
  build wiring, harness self-tests, test documentation.
- **Acceptance:** corpus digest/count check; complete/non-overlapping statuses;
  supported-regression and divergence-drift gates; malformed corpus rejection;
  unexpected passes surfaced; tool unit tests run under `zig build test`.
- **Tests:** synthetic extraction/tab/CRLF/malformed/status/exit fixtures.
- **Parallelism:** yes, tooling-only ownership.
- **Integration:** any time after current PR stack; avoid simultaneous edits to
  global test-count prose.
- **State:** integrated on main (PR #15); the manifest was 592 supported, 60
  not-yet, and 0 named divergences after the tab-stop/indented-code milestone
  (the former ATX trailing-backslash divergence now conforms). The manifest is
  a living artifact — M4 moved it to 636 supported / 16 not-yet / 0 divergences,
  M5 to 651 supported / 1 not-yet / 0 divergences, and M6 to 652 supported /
  0 not-yet / 0 divergences (full conformance)
  (see the M4/M5/M6 cards below).

## F1 — Frontmatter extraction (YAML / TOML)

- **Objective:** add a shared frontmatter pre-pass — sniff a `---` (YAML)
  or `+++` (TOML) fence at index 0, strip it before dispatch, and expose
  a parsed `metadata` object on the parse result for all three frontends
  (Markdown, Textile, Cooklang), per issue #66 (v0.5, "The Green Pastures
  Release").
- **Normative source:** the user's specification (issue #66); the existing
  Cooklang boundary contract (docs/COOKLANG.md §4, `tryFrontmatter`, the
  `unclosed-frontmatter` diagnostic) and its "never faked as parsed YAML"
  rule; the parsing is a **documented, bounded Oliver-chosen subset**, not
  a reference YAML/TOML implementation (clean-room session to be
  recorded).
- **Dependencies:** `source.Lines` iteration; the Cooklang
  `Frontmatter { raw, span }` model as the convergence target;
  `ParseResult` gains `metadata`.
- **Seams:** new `src/frontmatter.zig` (sniff, strip, subset parsers,
  diagnostics); `oliver.parse` + `ParseResult` (markdown/textile);
  `src/cooklang.zig` `tryFrontmatter` convergence; option plumbing
  (`ParseOptions.frontmatter: enum { none, yaml, toml } = .none` — off by
  default, because an index-0 `---` is today a §4.1 thematic break);
  fixtures `frontmatter-*` across all three frontends; docs/FRONTMATTER.md
  + nav.json; FEATURE-MATRIX rows (Markdown "front matter (extension)";
  the Cooklang row updated from "boundary only").
- **Acceptance:** `---\ntitle: Hello\n---\n\n# Doc` →
  `metadata.title == "Hello"` with the body exactly `# Doc` →
  `<h1>Doc</h1>`, across markdown, textile, and cooklang; the YAML subset
  (scalars, quoted strings, lists, indented maps, empty `---\n---` without
  panic); the TOML subset (`key = value`, tables, array-of-tables);
  out-of-subset payloads stay raw with a structured diagnostic; an
  unclosed opener degrades per the extended `unclosed-frontmatter`
  contract; default options byte-identical — 652/652 + full suite green.
- **Tests:** unit tests per subset + boundary shapes; fixture pairs per
  frontend; a Cooklang convergence pair; determinism checks.
- **Parallelism:** no while the shared pre-pass lands (it touches
  `oliver.parse`); fixture prep may proceed independently.
- **Integration:** first of the extension wave; after X1; the 652/652
  gate is re-verified.
- **State:** implemented on main (issue #66). `src/frontmatter.zig`
  landed: `preprocess` (sniff `---`/`+++` at index 0, strip before
  dispatch, `unclosed-frontmatter` pass-through, out-of-subset payloads
  stay raw with `frontmatter-parse-unsupported`), the bounded YAML
  subset parser (top-level mappings, raw-byte scalars, quoted forms,
  scalar lists, indented maps, comments, last-wins duplicates) and TOML
  subset parser (`key = value`, `[table]`, `[[array-of-tables]]`), and
  the public `Metadata`/`Entry`/`Value` model. `oliver.ParseOptions`
  gained `frontmatter` (default `.none` — corpus untouched, re-verified
  652/652); `ParseResult.metadata` and `Recipe.metadata` expose the
  parsed view; Cooklang's `tryFrontmatter`/`isFence` moved onto the
  shared pre-pass with the raw/span boundary contract intact (the
  existing boundary tests pass unchanged). Unit tests per subset + the
  diagnostic battery; fixture pairs `frontmatter-*` across all three
  frontends; an XHTML well-formedness case; docs/FRONTMATTER.md flipped
  to implemented, feature-matrix rows, README, DOCUMENT-MODEL,
  COOKLANG, nav/index, and CLEANROOM session 25.

## E1 — Modular wikilinks

- **Objective:** opt-in `[[Page Name]]` / `[[Page Name|Custom Label]]`
  inline wikilinks in the Markdown frontend, per issue #64 (v0.5).
- **Normative source:** Obsidian's de-facto wikilink syntax (user-facing
  documentation; clean-room session to be recorded) — no CommonMark/GFM/
  Textile reference carries the syntax, so this is a consumer-driven
  extension like footnotes/strikethrough.
- **Dependencies:** the extensions seam (`markdown.Options`), the inline
  scan → match → emit machinery, the link-bracket/autolink precedence
  rules.
- **Seams:** `src/markdown.zig` (`Options.wikilinks: bool = false`,
  `[[` discovery ahead of link brackets), `src/document.zig` (new
  `.wikilink` leaf, `data.wikilink = { target, label }`),
  `src/html.zig` (optional comptime resolver + default percent-encoded
  href; text = `label orelse target`), Markdown fixtures `wikilink-*`,
  docs/WIKILINKS.md + nav.json, FEATURE-MATRIX row.
- **Acceptance:** `[[Page Name]]` →
  `<a href="Page%20Name">Page Name</a>` (default resolver) byte-pinned;
  the label wins for visible text; a consumer resolver changes
  href/text deterministically; opaque in code spans/blocks, autolinks,
  link destinations/titles, image src/alt/title; every malformed shape
  (unterminated, empty target, extra pipes, trailing bracket, nested
  `[[`) stays literal and pinned; both resolver paths pass the XHTML
  well-formedness gate; off by default — 652/652 + full suite green.
- **Tests:** unit tests (node structure/spans, resolver paths, the
  literal battery); 3+ fixture pairs; a 10,000-link storm.
- **Parallelism:** yes; Markdown + model/renderer, Textile untouched.
- **Integration:** after F1 (shares the extension seam); the 652/652
  gate is re-verified.
- **State:** implemented on main (issue #64). `markdown.Options.wikilinks`,
  the `.wikilink` inline leaf, and the resolver-aware render arm
  (`html.RenderOptions.wikilink_resolver` + `wikilink_resolver_ctx`)
  landed with 4 fixture pairs (`wikilink-basic`/`literal`/`precedence`/
  `escapes`) and unit tests for structure, disabled behavior, the
  malformed battery, the greedy closer, link-text demotion, default +
  consumer resolver rendering, and a 10,000-wikilink determinism storm;
  the XHTML well-formedness gate covers both resolver paths
  (tests/xhtml_test.zig). The 652/652 gate is re-verified (off by
  default).

## E2 — Callouts / admonitions — implemented

- **Objective:** opt-in `> [!note] Title` callout blockquotes in the
  Markdown frontend, per issue #65 (v0.6, "The Obsidian Run").
- **Normative source:** Obsidian's published callout syntax (user-facing
  documentation; clean-room session 26 recorded in docs/CLEANROOM.md);
  the fallback behavior is an ordinary §5.1 blockquote.
- **Dependencies:** the container-block stack (§5.1), the extension
  seam, the model/renderer attribute machinery.
- **Seams:** `src/markdown.zig` (`Options.callouts: bool = false`;
  `[!type]` recognition on the blockquote's first content line),
  `src/document.zig` + `src/html.zig` (`.block_quote` gains optional
  `callout_type`/`callout_title`/`callout_title_nodes`, rendered
  `<div class="callout callout-<type>">` + `<div class="callout-title">`
  only when set — byte-identical `<blockquote>` otherwise), fixtures
  `callout-*`, docs/CALLOUTS.md + nav.json, FEATURE-MATRIX row.
- **Acceptance:** the `> [!note] Title` example byte-pinned;
  case-insensitive types; unknown types keep their name in
  `callout-<type>`; titleless callouts; multi-paragraph bodies, lazy
  continuation, nested callouts, lists/code/links inside bodies;
  non-callout shapes stay literal (extension off, mid-line,
  non-first-line, no separating space, `[!]`/`[!no close`); the XHTML
  gate passes; off by default — 652/652 + full suite green.
- **Tests:** unit tests (model payload, case-insensitivity, inline
  titles, the literal battery, default-off); 4 fixture pairs
  (`callout-basic`/`types`/`body`/`literal`); the XHTML well-formedness
  gate covers the div wrapper under both profiles.
- **Parallelism:** yes; Markdown + model/renderer, Textile untouched.
- **Integration:** after E1; the 652/652 gate is re-verified.
- **State:** implemented on main (issue #65). `markdown.Options.callouts`
  and the `tryTakeCallout` recognition on the blockquote's first content
  line landed with the `.block_quote` payload (`callout_type` normalized
  lowercase, `callout_title` source slice, `callout_title_nodes`
  inline-parsed — emphasis and wikilinks work in titles) and the div
  render arm; malformed shapes and mid-line `[!note]` stay literal; the
  full suite, the 652/652 gate, and the Cooklang 60/60 gate are all
  re-verified.

## E3 — Smart typography (`smartypants`) — implemented

- **Objective:** opt-in `smartypants` for CommonMark — the Textile
  character-replacement passes, one shared implementation, per issue #67
  (v1.0, "The Goodest Boy").
- **Normative source:** the already-documented Textile character-
  replacement contract (docs/TEXTILE-PARITY.md §13 + the T20 `{...}`
  macro table; clean-room sessions 10/13) — no new upstream material;
  the extraction and chosen scope are recorded in clean-room session 27
  (docs/CLEANROOM.md).
- **Dependencies:** the Textile `replaceChars`/`hasCharMacroTrigger`
  machinery (the borrow-or-copy contract), the inline text-node seam,
  the exemption set.
- **Seams:** the shared module `src/typography.zig` (extracted;
  `typography.replace(doc, span, char_macros)` — the macro table is
  enabled only by the Textile caller) with `src/textile.zig` as a
  caller (byte-identical output — the Textile wall is the regression
  net); `src/markdown.zig` (`Options.smartypants: bool = false`, applied
  in `emitText` to plain `.text` nodes — the escape split exempts
  `\"`/`\'`; code spans/blocks, autolinks, link destinations/titles,
  image src/alt/title, raw HTML tags, wikilink payloads, and image alt
  are exempt by construction); Markdown fixtures `smartypants-*`;
  docs/SMARTY.md + nav.json; FEATURE-MATRIX row.
- **Acceptance:** `"Hello," -- she said...` → `“Hello,” — she said…`;
  `2 x 4` → `2 × 4`; `(c)` → ©; apostrophes by position; exemptions
  pinned; the literal fallbacks (`---`, `....`, `(1/3)`, letter-touching
  hyphens) pinned; off by default — 652/652 + full suite green; Textile
  fixtures byte-identical after the extraction.
- **Tests:** unit tests (the replacement battery, braces-literal, escaped
  quotes, exemptions, scopes, fallbacks, default-off), 3 Markdown
  fixture pairs (`smartypants-basic`/`exempt`/`scopes`), an XHTML
  well-formedness case under both profiles, the Textile wall
  re-verified.
- **Parallelism:** no during the extraction (shared module);
  Markdown-side work may proceed once the module contract is fixed.
- **Integration:** after F1/E1; the 652/652 gate and the Textile wall
  are re-verified.
- **State:** implemented on main (issue #67). `src/typography.zig` now
  owns the shared pass; the Textile machinery moved onto it with
  byte-identical output (the fixture wall passed unchanged).
  `markdown.Options.smartypants` lands the same pass on plain text in
  every inline scope — headings (slug-safe: the non-ASCII replacement
  bytes are dropped by slugify), link display text, list items, GFM
  table cells, and callout titles/bodies — with the exemption set and
  the borrow-or-copy contract intact; the full suite, the 652/652 gate,
  and the Cooklang 60/60 gate are all re-verified.

## CK6 — Public string-quantity classify/scale + mixed numbers

- **Objective:** lift the exact-rational quantity grammar into a
  documented public string API so consumers that store Cooklang
  amounts as authored text (not a typed `Recipe`) can classify and
  scale without forking the operation; widen the canonical numeric
  forms by mixed `1 1/2`. Issue #76.
- **Normative sources:** the already-pinned CK3 conventions material
  (session 22 — "Scaling and Servings"); no new upstream spec. Mixed
  numbers and the string surface are Oliver's own markup-semantics
  choice, recorded in clean-room session 28. `parseQuantity`'s f64
  decimal arm is deliberately not the authority for scaling.
- **Dependencies:** CK3 `scaleRecipe` / exact rationals / `=` lock;
  `parseQuantity` stays the HTML/conformance numeric view.
- **Seams:** `src/cooklang.zig` (`classifyQuantity`, mixed-number arm
  of `parseQuantity`, `parseMixedNumber`); `src/cooklang_scale.zig`
  (`parseFactor`, `scaleAmount`, `scaleRecipe` calls `scaleAmount` on
  ingredient quantities only); `src/oliver.zig` (export comment);
  docs/COOKLANG.md §11 + FEATURE-MATRIX scaling row + TESTS.md +
  README + ARCHITECTURE + CAPABILITIES; `scale-mixed` fixture pair.
- **Acceptance:** `classifyQuantity("1 1/2") == scalable`; `"=1"`,
  `"1-2"`, `"some"` are `fixed`; `scaleAmount("1/2", ×2) → "1"`;
  `scaleAmount("1.5", ×3) → "4.5"` (decimal family preserved);
  `scaleAmount("=1", ×4) → "=1"` (`scaled` aliases `original`);
  `scaleRecipe` on `@flour{1 1/2%cup}` × 2 serializes a scaled
  amount; `@salt{=1%tsp}`, `#pot{2}`, `~{9%minutes}`, `@./sauce{2}`
  stay put; zero factors still `error.InvalidScaleFactor` (oliver#55
  stays closed). Existing `scale-basic` / `scale-servings` stay
  byte-identical.
- **Tests:** 2 parser unit tests (closed classify forms; mixed
  `parseQuantity`); 2 scale unit tests (string API + mixed through
  `scaleRecipe`); `scale-mixed` fixture pair (`1 1/2` × 2 → `3`,
  with lock/cookware/timer/ref pinned).
- **Parallelism:** yes; Markdown/Textile untouched; Cooklang HTML
  and the canonical corpus unchanged (mixed is a new form, not a
  corpus one).
- **Integration:** after CK3; the 652/652 and 60/60 gates are
  re-verified.
- **State:** this PR (issue #76).

## Deferred architectural cards

- **B1 HTML blocks (§4.6) types 1–5:** landed as M5 — comments, PIs,
  declarations, CDATA, and the `<script|pre|style|textarea` element set now
  end at their matching terminators; the §4.6 family is 44/44
  (docs/HTML-BLOCKS.md).
- **T2 Textile `@code@`:** integrated on main (PR #14); Textile-local inline
  scanner using the existing `.code_span` IR, with opacity and delimiter-storm
  tests (docs/TEXTILE-INLINE-CODE.md).
- **T3 Textile emphasis/strong:** follows T2; same-line boundary/nesting policy
  must be pinned from authoritative Textile documentation first.
