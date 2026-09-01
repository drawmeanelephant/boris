---
published_at: 2026-08-13T00:00:00Z
summary: Design and provenance contract for the first-class Cooklang (.cook) frontend: bytes in, a typed Recipe out.
---

# Cooklang frontend: design contract

Status: **CK1 — design and provenance contract** (see docs/WORK-LEDGER.md).

Oliver gains a first-class Cooklang (`*.cook`) frontend: bytes → a typed
`Recipe` semantic model with precise source spans and structured
diagnostics, plus an optional deterministic HTML rendering policy. This
document records the source hierarchy, the provenance of every upstream
artifact used, the chosen design, and the boundary between Cooklang
language semantics and ecosystem application behavior.

## 1. Mission and boundary

Oliver parses Cooklang. It does not cook.

```
Oliver:  bytes -> typed Recipe semantics -> optional deterministic
         serialization/rendering
Boris:   files, metadata authority, graph, recipe-reference resolution,
         templates, routes, publication, indexes, collection semantics,
         output policy
```

- Cooklang parsing has **no filesystem, network, or global-state
  dependencies**. Recipe references (`@./sauces/Hollandaise{150%g}`) are
  parsed as semantic references — the path string is preserved; resolving
  it against a recipe corpus is a consumer responsibility.
- The current spec's YAML front matter is recognized at its boundary and
  preserved as a raw borrowed payload with exact spans. By default
  Oliver does **not** parse arbitrary YAML (it has no reference YAML
  layer, and faking a subset would corrupt Boris's metadata authority).
  With the shared frontmatter extension on
  (`ParseOptions.frontmatter = .yaml`, docs/FRONTMATTER.md), the payload
  is additionally parsed into `Recipe.metadata` under a documented,
  bounded Oliver-chosen subset — never faked, out-of-subset payloads
  stay raw with a diagnostic. The canonical conformance harness
  (a dev-only tool) reads the corpus's flat `key: value` forms only.
- Application/ecosystem behavior — shopping lists, checked state, pantry,
  aisles, image discovery, collection indexing, search, meal scheduling,
  scaling *application logic*, publication — is explicitly out of scope
  (conventions.md documents these as ecosystem conventions, not language).
  `.menu` files are valid Cooklang (sections + recipe references) and parse
  through the same frontend; no meal-planning logic is built.

## 2. Source hierarchy and provenance

The mission's hierarchy, with the exact upstream artifacts used:

1. **Published language specification** — https://cooklang.org/docs/spec/
   (fetched 2026-08-13): ingredients, steps, comments, metadata,
   cookware, timers, notes, sections, shorthand preparations, recipe
   references.
2. **Formal EBNF** — `cooklang/spec` `EBNF.md`, commit
   `6c4788644004e604ae1da110af6d2400e3c9c7b0` — **explicitly marked
   "WIP, the EBNF is outdated and doesn't contain latest changes yet"**
   (recorded conflict in §4).
3. **Canonical test corpus** — `cooklang/spec` `tests/canonical.yaml`
   (`version: 7`), same commit, **MIT licensed** (LICENSE in the same
   repo). 60 tests covering text/ingredient/cookware/timer semantics and
   metadata. Fetched via raw.githubusercontent.com at the pinned commit;
   provenance recorded in docs/CLEANROOM.md session 21 and this doc.
4. **Official examples/user docs** — `cooklang/spec` `examples/*.cook`
   (4 recipes), same commit.
5. **Conventions documentation** — `cooklang/spec` `conventions.md`,
   same commit — used **only** for explicitly conventional behavior
   (`.menu` files, scaling semantics that must be *preserved*, canonical
   metadata keys). Scaling *application logic* is deferred.

Released spec proposals used for the current syntax of features absent
from the corpus and the outdated EBNF (both marked **Released** in the
same repo, same commit):

- `proposals/0005-note-blocks.md` — the `>` note block.
- `proposals/0006-sections.md` — `=` section headers.

No parser implementation source was consulted (no cooklang-rs, no
CookCLI internals, no tree-sitter grammar, no third-party parsers). See
docs/CLEANROOM.md session 21 for the full record.

## 3. The typed Recipe model

Cooklang is semantically richer than prose markup, so it does **not**
converge on the Markdown/Textile `document.Document` node tree. It has
its own typed model in `src/cooklang.zig`, reusing Oliver's
infrastructure (spans, diagnostics, arena ownership, byte borrowing,
`source.Lines`, unicode predicates, allocators/writers).

```
Recipe
  source: source.Source            (borrowed clean body — fences stripped)
  arena: ArenaAllocator            (owns nothing but the block list itself;
                                   text payloads are borrowed slices)
  frontmatter: ?Frontmatter        (raw YAML payload + exact spans, into the
                                   original input)
  metadata: ?frontmatter.Metadata  (parsed view, option on; docs/FRONTMATTER.md)
  blocks: []Block

Frontmatter { raw: []const u8, span: source.Span }

Block = union(enum) { step: Step, section: Section, note: Note }

Section { name: []const u8, name_span, span, blocks: []Block }
Note    { text: []const u8, span }
Step    { parts: []Part, span }

Part = union(enum) {
  text:      []const u8 (borrowed, span),
  ingredient: Ingredient,
  cookware:   Cookware,
  timer:      Timer,
  line_break: void,
}

Ingredient {
  name: []const u8, name_span: Span,
  quantity: ?[]const u8,   // source text inside {} before %; null when absent
  units:    ?[]const u8,   // source text after %; null when absent
  preparation: ?[]const u8, // shorthand ( ... ) after the braces
  is_recipe_reference: bool, // name begins with "./"
  span: Span,               // whole token (marker through closing })
}
Cookware { name, name_span, quantity: ?[]const u8, span }
Timer    { name, quantity: ?[]const u8, units: ?[]const u8, span }
```

Design decisions:

- **Quantity is source text, never coerced.** `@thyme{few%sprigs}` keeps
  `"few"`; `#frying pan{two small}` keeps `"two small"`; `@milk{1/2%cup}`
  keeps `"1/2"`. A derived numeric view (`numeric: ?Number` where Number
  is int/decimal/fraction) is exposed **only** for pure numeric forms
  (`2`, `1.5`, `1/2`, mixed `1 1/2`; `01/2` does **not** qualify) so the
  canonical harness and scaling can compare canonically without losing
  the source text. A mixed number's numeric view is its equivalent
  improper fraction; there is no mixed-number emission form.
- **Canonical defaults are applied by the conformance harness, not the
  model.** `@chilli` (no braces) has `quantity: null` in the model; the
  canonical semantics default ingredients to `"some"`, cookware to `1`,
  timers to `""`. The harness maps null per type; the model stays
  faithful to the source.
- **Comments are omitted from the semantic tree** (canonical evidence:
  `-- testing comments` parses to `steps: []`). They are consumed as
  trivia; every semantic node retains exact source spans.
- **Notes and sections are blocks, not steps.** Note text is plain text
  (not scanned for ingredients/cookware/timers — proposal 0005: notes are
  "not part of the cooking steps"). Section titles are plain text
  (proposal 0006: "The text of the section title is not parsed for
  ingredients or cookware"). Steps after a section header belong to that
  section until the next header or EOF; steps before any header are
  top-level.
- **Steps are paragraphs.** Blank-line-separated. Multi-line steps join
  with a single space (canonical `testCommentsAfterIngredients`:
  newline → space); a line ending in `\` produces an explicit
  `line_break` part (current spec "Forced line breaks").
- **Recipe references are a flag on Ingredient**, not a separate node:
  the syntax is the `@` ingredient syntax; the reference-ness is in the
  name shape (`./` prefix, per conventions.md: "paths are relative to the
  root recipe directory, without the .cook extension").

## 4. Grammar decisions and recorded conflicts

Every decision below is a *choice* recorded here, pinned by tests in
src/cooklang.zig and/or fixtures, never an accident.

- **EBNF vs current spec.** The EBNF is explicitly outdated: it lacks
  YAML front matter (its `metadata = ">", ">", ...` is the pre-frontmatter
  form), sections, shorthand preparations, and recipe references. The
  current spec + released proposals (0005, 0006) are authoritative for
  those. Where the EBNF is silent, the corpus and spec govern.
- **Multiword lookahead.** The EBNF's `multiword component = word,
  { text item - "{" }-, "{", ...` is outdated on this point: taken
  literally it makes `@salt and @pepper{1%tsp}` name the whole run up to
  the first `{`, but the current spec page's own example — "Add @salt
  and @ground black pepper{}" — proves `@salt` must stay single-word.
  The chosen rule (pinned by Oliver-owned tests): the name region runs
  to the first `{` **but stops early at a following token marker
  (`@`/`#`/`~`), at P-category punctuation, or at a `-`-free boundary**
  (hyphens and the `.`/`/` of recipe-reference paths are name
  characters, as the corpus's `#7-inch nonstick frying pan{ }` requires
  — and `-` itself ends a *single-word* name, since it is Pd and the
  EBNF's `word` excludes all P categories). So `@salt and @pepper{1%tsp}`
  is two ingredients; `@salt, @ground black pepper{2}` keeps `@salt`
  single-word at the comma; `@1000 island dressing{ }` keeps the whole
  phrase.
- **Single-word boundary = Unicode whitespace (Zs + TAB) or P-category
  punctuation only.** Symbols (S categories) are *not* boundaries — the
  corpus's `@🧂` (So category) requires this. A new P-only predicate in
  `src/unicode.zig` backs this (deliberately generalized shared
  primitive; see CLEANROOM session 21).
- **Invalid tokens degrade to text, not errors.** `Message me @ example`
  → one text part (corpus: invalid single/multi-word tests are text).
  The marker must be immediately followed by a word character.
- **Block comments** `[- ... -]` may span lines (EBNF). An unclosed `[-`
  with no `-]` to end of input is **literal text** (the construct fails
  to form — the same literal-fallback policy; no diagnostic, because the
  corpus treats failed constructs as text).
- **Frontmatter** requires both fences: the file's first line must be
  `---` (trailing whitespace/CR allowed) and a later line must be
  exactly `---`. Without a closing fence, the opener is ordinary step
  text (narrowest reading of the spec's "add --- at the beginning of a
  file and --- at the end"). `hello ---` mid-file is not a fence
  (corpus `testMetadataBreak`).
- **Line comments** `--` run to end of line; the space *before* `--`
  remains text (corpus: `"  and some text"` from `" "` + newline-space +
  `"and some text"`).
- **NUL / malformed UTF-8**: bytes are opaque; the P/whitespace
  predicates classify only valid decodable code points, so malformed
  sequences fall through as name/text bytes (Oliver's byte contract;
  NUL is not whitespace/punctuation, so it stays in runs).

## 5. Diagnostics

Malformed input follows the established Oliver frontend philosophy:
where the dialect permits, degradation to text **is** the documented
behavior (corpus-confirmed). Two tiers, both literal-fallback:

- **Corpus-pinned near-misses stay silent.** `@ example{}`, `~ {5}`,
  `~ 5`, `hello ---` mid-file — the corpus proves these are *correct*
  Cooklang text, so they produce no diagnostics at all.
- **Structural malformation warns.** Where the source clearly intends a
  construct that cannot be satisfied, the construct degrades to literal
  text (unchanged parse) **and** a warning diagnostic carries the exact
  location so consumers can surface it:
  - `unclosed-braces` — a `{` with no `}` on the line.
  - `unclosed-preparation` — a `(` immediately after a token's `}` with
    no `)` on the line (the `(` stays text; the token still parses).
  - `unclosed-block-comment` — a `[-` with no `-]` anywhere in the step.
  - `unclosed-frontmatter` — a leading `---` fence never closed (the
    opener stays ordinary step text).

Diagnostics are `severity: warning`, carry 1-based `offset`/`line`/
`column` plus the half-open byte `span`, and are allocated in the
recipe's arena (owned by the result). Resource/API failures (OOM, input
too large) remain Zig errors from the parse entry point, never
diagnostics.

## 6. Public API and CLI

- `oliver.cooklang.parse(allocator, input, options) -> CooklangResult`
  where `CooklangResult { recipe: Recipe, diagnostics: []Diagnostic }`.
  This is an explicit entry point because the result type is a typed
  Recipe, not a `document.Document` — shoehorning it into
  `oliver.parse(..., .markdown/.textile, ...)` would force the recipe
  semantics through an IR that cannot carry them. The existing
  Markdown/Textile API is untouched (source-compatible).
- CLI: `oliver render --from cooklang` renders the recipe through the
  Cooklang HTML policy; `--to xhtml` selects the same policy under the
  XML-compatible profile (the forced line break becomes `<br />`;
  docs/XHTML.md). `oliver serialize --from cooklang` writes the
  canonical `.cook` text (§10).

## 7. HTML rendering policy (Oliver-owned, not Cooklang-conformant)

The Cooklang spec defines recipe semantics, not an HTML vocabulary.
Oliver therefore documents its own deterministic policy in
`src/cooklang_html.zig` — separate from `src/html.zig`'s single entry —
and never claims Cooklang conformance for it. Consumers (e.g. Boris)
may instead consume the `Recipe` IR directly and own layout.

Vocabulary (as implemented; the richer generic policy):

- recipe wrapper: `<article class="recipe">`
- **ingredients index**: `<section class="ingredients">` with
  `<h2>Ingredients</h2>` and one `<li>` per **distinct** ingredient
  (exact, case-sensitive name; first occurrence's quantity, units, and
  preparation; first-appearance order). Each item carries
  `data-quantity`/`data-units` when present, a visible
  `<span class="quantity">200 g</span>`, the name, and an optional
  `<span class="preparation">grated</span>`; recipe references appear
  as `<li class="recipe-ref" data-ref="…">`; cookware and timers are
  not ingredients and never appear. The index is omitted when the
  recipe has no ingredient/reference tokens. It is a deterministic
  summary for generic publication — aggregating quantities or building
  shopping lists is ecosystem logic Oliver deliberately does not own.
- sections: `<section>` with `<h2>Name</h2>` (the `<h2>` is omitted for
  an unnamed section); each section owns its step `<ol>` and notes
- step list: `<ol class="steps">` with `<li>`; a forced line break
  renders `<br>`; a note renders `<aside class="note">`
- ingredient (inline): `<span class="ingredient" data-quantity="…"
  data-units="…">name</span>` — `data-quantity`/`data-units` emitted
  only when present; preparations render `<span
  class="preparation">…</span>` inside their ingredient
- recipe reference: `<span class="recipe-ref"
  data-ref="./sauces/Hollandaise">./sauces/Hollandaise</span>` —
  distinct from a plain ingredient; never resolved
- cookware: `<span class="cookware" …>`
- timer: `<time class="timer" data-quantity="25" data-units="minutes"
  datetime="PT25M">25 minutes</time>` — `datetime` is an ISO-8601
  duration emitted when the quantity is a whole number and the unit is
  a recognized day/hour/minute/second form (singular/plural and common
  abbreviations, case-insensitive); fractional or unknown-unit timers
  keep the `data-quantity`/`data-units` contract without `datetime`.
  Named timers render `eggs (3 minutes)` when braced, else the bare
  name; unnamed timers show the quantity and units
- text: HTML-escaped like Markdown/Textile text
- frontmatter is **not** rendered into HTML (it is data; the Recipe IR
  carries it)

## 8. Conformance wall

- **Canonical corpus**: `tools/cooklang_conformance.zig` runs every test
  in `tests/cooklang/canonical.yaml` (vendored from the pinned commit,
  MIT, provenance in this doc and docs/CLEANROOM.md) through
  `cooklang.parse`, comparing parts and metadata against the canonical
  expectations (YAML numbers compared via the derived numeric view;
  YAML strings via source text; null quantity mapped to the canonical
  default per type). Registered as `zig build cooklang-conformance`;
  with no path argument the vendored corpus is used, and a path may be
  passed to check a freshly fetched copy. The harness also asserts the
  serializer's semantic fixed point over every corpus source (§10), so
  canonical output never drifts from what the canonical tests accept.
- **Owned tests**: 22 parser unit tests in `src/cooklang.zig` and 2
  serializer unit tests in `src/cooklang_serialize.zig` (exact spans
  and model shape, every semantic family, diagnostics, bounded
  behavior, the serialize round-trip fixed point — all running under
  `zig build test`), fixture pairs in `tests/fixtures/cooklang/`
  (input + expected HTML: `cooklang-basic`, `cooklang-sections`,
  `cooklang-frontmatter`, `cooklang-literal`; input + expected
  canonical output: `serialize-basic`, `serialize-literal`), and
  adversarial/resource tests in `tests/fixtures_test.zig` (huge
  delimiter runs, thousands of ingredients, deep preparations, an
  unterminated block comment, many steps/sections, a 100 KB single
  line) proving deterministic output and no pathological rescans.
- **Regression wall**: the CommonMark gate stays 652/652 with 0
  mismatches; the Textile suite stays green; `zig fmt --check` clean.## 9. Explicitly deferred (documented, not built)

All of conventions.md's application features: shopping lists, pantry,
aisles, image discovery, search, meal scheduling, publication, and
filesystem recipe-reference resolution. These are consumer/ecosystem
responsibilities, per §1. (The canonical serializer — §10 — the pure
scaling operation — §11 — the richer generic HTML renderer — §7 — and
the `.menu` convenience view — §12 — were the four stretch goals, now
implemented.)

## 10. Canonical serializer (Oliver-owned, not byte-identical round-trip)

`src/cooklang_serialize.zig` turns a semantic `Recipe` back into valid
`.cook` text: `oliver.cooklang_serialize.serialize(allocator, writer,
&recipe, .{})`, or `oliver serialize --from cooklang` on the CLI. It is
**canonical serialization, not byte-identical source round-tripping**:
parsing normalizes away the source's exact spelling (marker style,
whitespace, `== Name ==` vs `= Name`, comment placement), so the output
is one deterministic valid spelling of the same recipe — not the
original text. A byte-identical round-trip would require a CST/trivia
layer; that is explicitly out of scope, and this distinction is
recorded here and in the module docstring so nobody mistakes canonical
output for the source.

Canonical rules (as implemented):

- Blocks render in order, separated by one blank line, ending with a
  single `\n`; front matter renders first as `---\n` + raw payload +
  `---\n` (the payload passes through byte-for-byte — it is data, not
  parsed).
- A step renders its parts in order: text verbatim (text values are
  already join-normalized by the parser, so a multi-line step without
  forced breaks collapses to one line), tokens in canonical form, and
  a `line_break` part as `\` + `\n`.
- Tokens emit braces exactly when the model says they carried them
  (`quantity != null`; the empty-braces form `@x{}` is `quantity = ""`,
  distinct from no braces at all), `%units` only when units are
  non-empty, and the shorthand `(preparation)` follows the closing
  brace verbatim. Recipe references need no special form:
  `is_recipe_reference` is a derived flag, and the name renders as-is.
- Notes render as `> ` plus the text; sections render as `= Name` (the
  `== Name ==` variant normalizes to `= Name`).
- No escaping is needed or performed: text values cannot contain a
  valid token shape (it would have parsed as one) or a trailing `\`
  (it would be a break), so verbatim emission re-parses to the same
  parts; `-`/`[-`-carrying literal text re-parses identically by the
  same rules the parser applies.

Contract, verified by tests:

- **Semantic fixed point**: `parse(serialize(parse(x)))` is
  semantically identical to `parse(x)` (source spans excepted — they
  are positions in different texts), and `serialize(serialize(x))` is
  byte-identical: serialization is idempotent.
- **Corpus wall**: the conformance harness asserts the fixed point over
  every source in the official 60-test corpus, so canonical output
  never drifts from what the canonical tests accept.
- **Fixture pairs**: `serialize-basic` and `serialize-literal` pin
  canonical output byte-for-byte, including the degraded/literal
  shapes that must round-trip unchanged.
- **Parser fix carried**: empty front matter (`---\n---`) — the
  zero-payload case — parses correctly (no panic) and round-trips.

## 11. Scaling (pure semantic operation)

`src/cooklang_scale.zig` is two surfaces on one exact-rational grammar:

- **String primitives**, for consumers that store amounts as authored
  text rather than a typed `Recipe`:
  `oliver.cooklang.classifyQuantity(amount)` → `empty` | `scalable` |
  `fixed`; `oliver.cooklang_scale.parseFactor(text)` → an exact
  rational (`error.InvalidScaleFactor` for 0, a 0-denominator, or a
  non-scalable form); `oliver.cooklang_scale.scaleAmount(allocator,
  amount, factor)` → `{ class, original, scaled }`. The same three
  names are re-exported from `cooklang_scale`.
- **`scaleRecipe`**, the whole-recipe operation:
  `oliver.cooklang_scale.scaleRecipe(allocator, &recipe, by)`, or
  `oliver scale --from cooklang (--factor <num[/den]> | --servings
  <n>)` on the CLI. It calls `scaleAmount` on ingredient quantities
  only. It is pure and deterministic: no filesystem, network, or
  global state; the input recipe is never mutated.

Semantics follow the official conventions' "Scaling and Servings"
section (https://cooklang.org/docs/conventions/; provenance in
docs/CLEANROOM.md session 22). The string surface and mixed numbers
are Oliver-chosen markup semantics (session 28).

Closed classify rules (after trimming ASCII space/tab):

| Class      | Forms                                                                                          |
| ---------- | ---------------------------------------------------------------------------------------------- |
| `empty`    | `""`                                                                                           |
| `scalable` | unsigned integer; `a/b` with `b ≠ 0` (spaces around `/` accepted); decimal `a.b`; mixed `a b/c` |
| `fixed`    | everything else, including `=…`, ranges (`1-2`), words (`some`), `1/0`, leading zeros (`02`)   |

A mixed number is a whole part plus a proper fraction (`num < den`,
`den ≠ 0`), separated by one or more ASCII space/tab (the same trim
set used elsewhere). `1 1/2` is scalable; `1 3/2` is not. A leading
`=` is `fixed` even if the rest would parse (`=1`, `=1/2`).

`scaleAmount`:

- `scalable` → exact rational product, same formatting policy as
  `scaleRecipe` (whole → integer; decimal-family + terminating den →
  decimal; else reduced `num/den`; overflow → leave original).
- `empty` / `fixed` → `scaled` aliases `original`.
- `parseFactor` accepts the same scalable forms as amounts.

What scales on a `Recipe`, what does not (per the conventions):

- Ingredient quantities scale **linearly** by an exact rational factor.
- **Fixed quantities** — a leading `=` (`@salt{=1%tsp}`) — stay
  byte-for-byte unchanged.
- **Recipe references** (`@./path{2}`) are never touched: their
  quantities are directives for scaling the *referenced* recipe, which
  Oliver does not resolve (consumer concern).
- **Timers and cookware never scale** (cooking times and pan sizes do
  not follow portion size).
- **Non-numeric quantities** (`@salt`, `@x{}`, `@x{two small}`) are
  unchanged — there is nothing numeric to scale.

Two modes (`ScaleBy`): `.factor` multiplies by an exact rational
`num/den`; `.servings` scales to a target serving count, reading the
current count from the frontmatter `servings`/`serves`/`yield` key
(leading number only, per the conventions; default 1 when absent,
zero, or non-numeric). Oliver does not parse YAML — this is a
conservative line-oriented read of the raw payload only. A zero
`num`, a zero `den`, or a zero target is `error.InvalidScaleFactor`
(scaling to nothing is degenerate, and a zero denominator is division
by zero).

Arithmetic and formatting policy:

- Quantities are read as **exact rationals** directly from their source
  text (never through f64), multiplied, and reduced. A whole result
  emits an integer; a non-whole result emits a reduced fraction
  `num/den`, except a **decimal-family source** whose reduced
  denominator has only 2 and 5 factors, which emits the exact
  terminating decimal (bounded at 12 fractional digits). Results whose
  exact representation would overflow 128-bit arithmetic are left
  unchanged. Mixed numbers are a canonical **input** form; emission
  stays integer / fraction / terminating decimal (no mixed-number
  output). Examples: `1/2 × 2 = 1`, `1/2 × 3 = 3/2`, `1.5 × 3 =
  4.5`, `1 1/2 × 2 = 3`, `0.1 × 4/3 = 2/15` (fraction, since 15 has a
  3 factor).
- The frontmatter is passed through raw and unmodified: Oliver does not
  rewrite metadata, and the input recipe is never changed. Re-scaling
  the derived recipe is therefore the caller's responsibility.
- The scaled `Recipe` owns a fresh arena; synthesized quantity text
  lives in it and everything else is a shallow copy, so the input
  recipe (and its source bytes) must outlive the scaled result. Spans
  of synthesized quantities still point at the source quantity region
  (derived recipes are not re-parses).

Verification: unit tests pin the families above (exactness,
servings-mode metadata keys, invalid-factor rejection, sections/notes,
numeric-view recomputation, empty input, the public string API, mixed
numbers), and `scale-basic` / `scale-servings` / `scale-mixed`
fixture pairs pin the canonical scaled output byte-for-byte. The
scaled output is valid `.cook` by construction (the serializer is the
emission path) and re-parses consistently.

## 12. Menu profile (.menu view)

A `.menu` file is, per the conventions' "Menu Files" section, a
**valid Cooklang file** that uses sections for days (or meals) and
recipe references to compose a plan. Oliver therefore has no second
parser: `.menu` content runs through the ordinary Cooklang frontend,
and `src/cooklang_menu.zig` is the explicit convenience layer exposing
the menu *structure* semantically:

    Menu { days: []Day }
    Day  { name, date: ?Date, references: []Reference }
    Reference { path, quantity, units }

`oliver.cooklang_menu.menuView(allocator, &recipe) -> Menu` builds the
view; `writeMenu` renders a deterministic plain-text dump (one line
per day: `Day 1 (2026-03-07): ./breakfast/shakshuka{4%servings}`),
shared by the `oliver menu --from cooklang` CLI and the fixtures.

Rules (pinned by tests):

- Every **top-level section is a day**, in order. An ISO date in the
  title is recognized only as a trailing `(YYYY-MM-DD)` group with a
  valid month (1–12) and day (1–31) — `Day 1 (2026-03-07)` splits into
  name "Day 1" + date; any other shape leaves the whole title as the
  name, conservatively.
- A day's **recipe references** are collected in step order, each with
  its path and its scaling directive preserved as source text (`{2}`,
  `{}`, `{4%servings}`). References are never deduplicated (each
  occurrence is a directive) and never resolved — filesystem
  resolution remains a consumer concern.
- Non-section top-level blocks are not part of the menu view (a
  well-formed `.menu` file has none); they stay visible in the Recipe.
- Ownership: the `Menu` owns its day/reference arrays (fresh arena);
  the string payloads borrow the Recipe, which must outlive the view.
- This is a **view**, not a meal-planning application: no shopping
  logic, no date scheduling, no filesystem access. Boris owns those.

Verification: 6 unit tests (day/date extraction, directives,
conservative date parsing, top-level ignores, empty/reference-less
inputs, the conventions example byte-for-byte) and the `menu-basic`
fixture pair (the conventions' own Monday–Wednesday + dated-days
example) pin the view and its text dump.
