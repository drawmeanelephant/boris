# Bounded Cooklang recipe input adapter

**Status:** normative, additive input compatibility slice
**CLI selector:** `--cooklang`
**Adapter identity:** `boris-cooklang-seam-v1`
**IR facet:** `recipe` (IR `0.4.0`)

Cooklang is a plain-text recipe markup language: prose steps with sigils that
make ingredients, cookware, timers and durations machine-parsable. This slice is
an adapter into Boris, not a Cooklang implementation and not a second site
compiler.

Syntax names and examples below are grounded in the official
[Cooklang specification](https://cooklang.org/docs/spec/). Boris accepts only
the closed subset in this contract.

Unlike the Textile slice, this adapter has a second output. A recipe's value is
not its prose — it is the structured ingredient, cookware and timer data, which
reaches the IR as the `recipe` node facet. An ingredient list rendered only as
Markdown would be unqueryable.

## Why frontmatter needs no adapter

Cooklang metadata *is* YAML front matter delimited by `---`, which is already
the Boris frontmatter grammar. The adapter therefore never sees metadata:
`parser.zig` splits frontmatter from the original source bytes first, and only
the body is adapted. `id`, `title`, `parent`, `tags`, semantic relations, and
the closed `servings` exception behave exactly as they do for a Markdown page.
`serves` and `yield` are input aliases for `servings`; every other Cooklang
metadata name stays `EFRONTMATTER`. See [frontmatter.md](frontmatter.md).

## Activation and discovery

- `--cooklang` is an input-format modifier. It combines with the existing HTML
  default, IR, RAG, `check`, `impact`, incremental, watch, jobs, and
  multi-target output selectors.
- Without `--cooklang`, page discovery accepts lowercase `.md` and `.mdx` only.
- With `--cooklang`, page discovery accepts lowercase `.cook` only.
- Extensions are case-sensitive. `.COOK` is not a page.
- `--cooklang` and `--textile` together are a usage error: each is a whole-tree
  mode that refuses the other's extension.
- A page tree mixing `.cook` with any other page extension fails with
  `ECOOKLANG`; Boris never guesses a dialect per page. A `.cook`-only tree
  invoked without `--cooklang`, or a non-`.cook` tree invoked with it, fails the
  same way with a mode-selection remediation.
- Entity ids derive from `.cook` paths by the ordinary rule, so a recipe path
  may not contain a space (`validateEntityId`).

## Pipeline position and invariants

```text
scan .cook
  -> parse the existing Boris frontmatter from original source bytes
  -> adapt ONLY the body: Cooklang -> Markdown + Recipe
  -> include expansion, wiki rewrite, Aside tokenization, Oliver render  (unchanged)
```

- The seam is pure: no filesystem, renderer, layout, graph, or process access.
- Adaptation is total and deterministic; the same body always produces the same
  Markdown and the same `Recipe`.
- **Seam** diagnostic lines and columns refer to the author's `.cook` file.
  Oliver reports positions against the body it parsed, so the line and column
  an author sees match the `.cook` source.
- **Graph** diagnostics (`EREFERENCEMISSING` and friends) are located against
  the *adapted* Markdown, which the adapter restructures — the ingredient list
  is synthesized before the method — so their line numbers do not correspond to
  positions in the `.cook` file. See Known limitations.
- `adapter_identity` is part of each page's cache-key material, so switching
  input format invalidates fingerprints rather than serving a stale page.

## Accepted syntax

| Construct | Source | Effect |
|---|---|---|
| Ingredient, one word | `@salt` | Name ends at whitespace or sentence punctuation |
| Ingredient, multi-word | `@ground black pepper{}` | Name ends at `{`, which must touch the name |
| Quantity | `@potato{2}` | `amount` = `2` |
| Quantity with unit | `@bacon{1%kg}` | `amount` = `1`, `unit` = `kg` |
| Preparation | `@onion{1}(peeled)` | `preparation` = `peeled` |
| Recipe reference | `@./sauces/pepper-oil{1%tbsp}` | `recipeRef` = `sauces/pepper-oil`; the `./` prefix is required |
| Cookware | `#pot`, `#potato masher{}` | Recorded in `cookware` |
| Timer, anonymous | `~{25%minutes}` | Recorded in `timers`, renders as `25 minutes` |
| Timer, named | `~eggs{3%minutes}` | `name` = `eggs`, for app notifications |
| Step | paragraph | One numbered Method item |
| Forced break | trailing `\` | CommonMark hard break — the same character |
| Note | `> text` | Markdown blockquote |
| Section | `= Dough`, `== Filling ==` | `###` heading inside Method; numbering restarts |
| Line comment | `-- text` | Removed |
| Block comment | `[- text -]` | Removed, may span lines |

### Name termination

A brace-less name is one word. A name containing spaces must be closed with
`{`, and that `{` **must touch the name** — no space between them. The
lookahead for it also stops at another sigil (`@`, `#`, `~`), at a bracket, or
at sentence punctuation followed by a space or end of line.

Both conditions are load-bearing. Without the sigil stop,
`add @salt and @pepper{1}` reads `salt and @pepper` as one name. Without the
adjacency rule, `add @salt into the {bowl}` reads `salt into the` as the name
and `bowl` as its amount, deleting the prose between them from the rendered
step — an unrelated braced word later in a sentence is not part of the name.

Punctuation is judged in context: the `.` in `@./sauces/pepper-oil` and in
`@milk{1.5%l}` belongs to the token, while the `.` in `add @salt.` ends the
sentence.

## Rendered document shape

Deterministic and fixed:

1. `## Ingredients` — one bullet per ingredient reference, with `— amount unit`
   and `(preparation)` when present.
2. `## Cookware` — one bullet per cookware reference.
3. `## Method` — steps as an ordered list, author sections as `###` headings,
   notes as blockquotes.

An empty group is omitted entirely rather than rendered as an empty heading.

Within a step, an ingredient and a cookware item render as their name and a
timer renders as its duration, so the prose reads as a sentence. Quantities live
in the ingredient list, which is where a cook reads them.

A recipe reference renders in the ingredient list as a Boris wiki link
(`[[sauces/pepper-oil]]`). This is deliberate: the reference becomes a validated
graph edge of kind `reference`, so a reference to a recipe that does not exist
fails the build instead of rendering as dead prose. The seam emits Boris syntax
here; author-written `[[` is escaped as inert text (below).

Because the adapter synthesizes that link, the derived id must satisfy **both**
consumers before it is emitted: `identity.validateEntityId` (no traversal, no
absolute path, no whitespace, no `#`, `?`, `%`) *and* `wikilink.zig`'s narrower
grammar, `[A-Za-z0-9/_.-]`. Anything else is refused with `ECOOKLANG`. Checking
only the first let two bugs through: a `|` was read as the wiki label separator,
so `@./index|Anything` published an edge to `index` while the IR recorded
`index|Anything` — a reference that did not match the edge it created and was not
joinable against `nodes[].id`; and a non-ASCII id such as `@./sauces/café`
passed only to fail later as `EREFERENCESYNTAX`, quoting generated syntax the
author never wrote.

The `./` prefix is required. Treating any name containing `/` as a reference
turned an ordinary ingredient into a synthesized wiki link, so
`@half/half{1%cup}` failed the build telling the author to fix a wiki link they
had not written.

## Escaping and refusals

Recipe prose is untrusted input, and the escape set is judged against **the
engine Boris links, not against CommonMark alone**. That engine changed: Oliver
replaced ApexMarkdown Unified. Oliver is CommonMark 0.31.2 plus GFM tables and
four opted-in extensions — heading attributes, footnotes, definition lists and
strikethrough. See [oliver-renderer.md](oliver-renderer.md).

| Character | Treatment | Live construct on Oliver |
|---|---|---|
| `&` `<` `>` | entity | raw-HTML and entity interpretation |
| `[` `]` | backslash | footnote reference (`[^1]`), link |
| `~` | backslash | GFM strikethrough (`~~x~~`); also the timer sigil |
| `=` | backslash | setext underline, which promotes the previous line to a heading |
| `` ` `` `*` `_` `#` `+` `-` `!` `\|` | backslash | code span, emphasis, heading, list item, image, table cell |
| `{` `}` | backslash | heading attribute list (`{#id .class}`) |
| `:` at the start of a line | `&#58;` | definition list (`Term` then `: def`) |
| digits then `.` or `)` at line start | backslash | ordered-list marker, which would nest a list inside the step |
| `:` elsewhere | passed through | nothing — and escaping every one would litter the corpus |
| `"` `^` `$` | entity / backslash | **nothing on Oliver.** Kept deliberately; see below |
| `:` adjacent to another `:` | `&#58;` | **nothing on Oliver.** Kept deliberately; see below |

### What is defence in depth, and why it stays

`"`, `^`, `$` and the `::` colon pair were live under Apex and are inert under
Oliver, verified by rendering each through the linked engine. They are kept
because escaping them costs nothing under CommonMark and because their absence
is what made the adapter unsafe the first time. Concretely, under Apex:

- A fenced div emitted its class into `class="…"` unescaped, so
  `:::x"onmouseover="alert(1)` on a step continuation line published
  `<div class="x"onmouseover="alert(1)">`. Oliver has no fenced divs.
- `find_def_separator` scanned a whole line for `::`, so the plainest step,
  `Reduce the sauce :: then plate it.`, was rewritten into
  `<dl><dt>1. Reduce the sauce</dt><dd>then plate it.</dd>`. Oliver's definition
  lists are the line-initial form only.

Two details remain load-bearing and were measured, not assumed:

- The colon uses a **numeric character reference, not a backslash**. Under Apex
  the definition-list pass ran before parsing and never saw a backslash escape:
  `&#58;::x` still opened a fenced div because the literal `::` survived. An
  entity is inert to a preprocessor and to a block parser alike, so it is
  correct on both engines.
- Colon adjacency is judged against the **output** buffer, not the input span. A
  pair can be assembled across two spans where neither half can see it:
  `Mix @salt:{1}: done` emitted `salt:` from the ingredient name and `:` from
  the following prose, producing `Mix salt:: done`.

A guard in this table may be removed only after rendering its construct through
the currently linked engine and showing it is inert. Reasoning from the
extension list alone is what produced the injection above.

Every author-controlled span is guarded, not just step prose: a token name, a
`{quantity}`, a `(preparation)` and a section name all reach published output.

Parsing is Oliver's: there is deliberately **no parser in Boris** (see
[oliver-renderer.md](oliver-renderer.md) for the pin and its boundaries).
Everything below therefore falls into one of three classes.

**Degrades to inert literal text with a structured warning.** Oliver never
crashes on malformed input and Boris never synthesizes a second parser to
second-guess it. An unterminated `{`, `(`, or `[-` degrades to literal text and
carries a structured warning with Oliver's stable code and the exact position
(`unclosed-braces`, `unclosed-preparation`, `unclosed-block-comment`; the
body-only frontmatter-fence case reports `unclosed-frontmatter`). A `(` only
counts as a construct after an ingredient's `{quantity}` — a bare `(` in prose
is not Cooklang syntax and stays silent. The literal is escaped like any other
author text, so it cannot forge document structure. The exact warning lines are
pinned below in [Diagnostic output](#diagnostic-output).

**Degrades silently to literal text.** `{{ … }}` macros, `[[ … ]]` wiki links,
raw HTML, an empty ingredient or cookware name (a bare `@{}` or `#{}`), and a
nested `{` in a quantity or `(` in a preparation all parse as ordinary prose on
Oliver; the escaping table above makes that prose inert in the rendered
document. They are not refusals.

**Fails the build with `ECOOKLANG`** — the refusals that protect published
output, all checked by the seam after the parse:

- control characters other than tab, newline, or carriage return
- a timer with neither a name nor a duration, including `~{}`
- a section with no name between its `=` markers
- a recipe reference that is not a valid page id (below)
- a token name longer than `max_token_name_bytes`, or more than
  `max_ingredient_count` / `max_cookware_count` / `max_timer_count` items

### Diagnostic output

Malformed structure never fails the build: an unterminated `{`, `(`, or `[-`
degrades to literal text and the build completes with **exit code 0**. Each
construct prints one warning line on stderr carrying Oliver's stable code, the
content-root-relative path, and the body-relative line and column of the
opening delimiter. Verified against the pinned Oliver revision (see
[oliver-renderer.md](oliver-renderer.md)):

| Code | Trigger |
|---|---|
| `unclosed-braces` | `{` with no `}` on the line |
| `unclosed-preparation` | `(` after an ingredient's `{quantity}`, with no `)` on the line |
| `unclosed-block-comment` | `[-` with no `-]` in the step |
| `unclosed-frontmatter` | a body-only `---` fence with no close |

The pipeline path (IR, RAG, `check`, `impact`) reports through the structured
diagnostic formatter, which appends the remediation hint; the HTML path prints
the same line without it, once at load time:

```text
# pipeline:  boris --cooklang --input content --out .boris
warning: ECOOKLANG: broken.cook:12:6: unclosed-block-comment: unclosed block comment `[-` (no `-]` in the step) [Fix or remove the malformed Cooklang syntax]
warning: ECOOKLANG: index.cook:8:11: unclosed-braces: unclosed `{` (no `}` on the line) [Fix or remove the malformed Cooklang syntax]

# html:  boris --cooklang --input content --html-dir dist --html-layout layouts/main.html
warning: ECOOKLANG: broken.cook:12:6: unclosed-block-comment: unclosed block comment `[-` (no `-]` in the step)
warning: ECOOKLANG: index.cook:8:11: unclosed-braces: unclosed `{` (no `}` on the line)
```

Both examples come from the same two-page corpus: `broken.cook` line 12 is
`Stir [- never closed.` and `index.cook` line 8 is `Mix @flour{200%g to the
bowl.`. Both builds succeed (`exit 0`): the IR run writes `manifest.json`,
`graph.json` and `build-report.json`, and the HTML run writes every page.

The column points at the opening delimiter — the author's own character — and
the pipeline orders diagnostics by path, then line, then column. The HTML path
prints in page order at load time, once per warning: its validation pass is the
only one that runs for every page, so even the cache-reused pages of an
incremental build (which skip render entirely) still report. (Graph
diagnostics on the *adapted* Markdown are a separate matter; see Known
limitations.)

### Bounds

The `recipe` facet is the first thing to copy author text verbatim into
`graph.json`, so it carries its own limits for the same reason the IR 0.3
relations facet carries `max_relation_count`: without them a 1 MiB `.cook` file
of `@a{1}` repeats publishes tens of megabytes of IR from one page.

| Bound | Value |
|---|---|
| `max_ingredient_count` | 512 |
| `max_cookware_count` | 128 |
| `max_timer_count` | 128 |
| `max_token_name_bytes` | 256 |

## The `recipe` IR facet

`recipe` is emitted on every `graph.json` node once **any** page in the corpus
carries one, and is `null` for pages that do not. Schema:
[`ir-graph-0.4.0.schema.json`](schemas/ir-graph-0.4.0.schema.json).

```json
"recipe": {
  "ingredients": [
    { "name": "spaghetti", "quantity": { "amount": "400", "unit": "g" },
      "preparation": "", "recipeRef": null }
  ],
  "cookware": [ { "name": "large pot", "quantity": { "amount": "", "unit": "" } } ],
  "timers":   [ { "name": "pasta", "quantity": { "amount": "9", "unit": "minutes" } } ]
}
```

Two properties are contractual:

**Quantities are strings.** Cooklang admits `2`, `1/2`, `1.5`, `1-2` and bare
words like `some`. Converting them to numbers in the IR would either reject
valid recipes or silently round them, so `graph.json` keeps what the author
wrote. Scaling is a separate, compiler-owned operation over those strings
(see [Scaling](#scaling)); the editor must not invent local arithmetic.

**References are never merged.** Each list holds one entry per reference in
authored order. Merging two `@flour` references means adding `200%g` to `1%cup`,
which is not decidable without a unit model. A consumer that wants a combined
shopping list can group these; a consumer that wants fidelity has it.

`recipeRef` is an entity id, joinable against `nodes[].id`, so a consumer can
follow a sub-recipe without re-parsing an ingredient name.

## Scaling

Scaling is defined over the authored amount **string**, not over a numeric IR
field. Source `.cook` files stay canonical. Classification and exact-rational
rewrite are Oliver's public string API (oliver#77); `src/recipe_scale.zig` is
the Boris wrapper and adds the timer lock. The grammar below is that API.

### Classification

After trimming ASCII spaces and tabs, an amount is exactly one of:

| Class | Forms |
|---|---|
| `empty` | `""` |
| `scalable` | unsigned integer with no leading zero (`2`, `400`); fraction `a/b` with `b ≠ 0` (`1/2`, spaces around `/` allowed); decimal `a.b` (`1.5`); mixed number `a b/c` where `c ≠ 0` and `b < c` (`1 1/2`) |
| `fixed` | everything else, including ranges (`1-2`), words (`some`, `a pinch`), `1/0`, leading zeros (`02`), improper mixed numbers (`1 3/2`), and a leading `=` (`=1`) |

Decimals require a single `.` and only digits on each side that is present.
No other forms are scalable.

### Operation

A factor uses the same scalable forms. Zero and a zero denominator are invalid.

- **Ingredients and cookware:** scalable amounts are multiplied by the factor
  as exact rationals. A whole result emits an integer; a decimal-family source
  whose reduced denominator is `2^a·5^b` emits a terminating decimal
  (`1.5 × 3 = 4.5`); otherwise a reduced `num/den`. Overflow leaves the
  authored amount unchanged. Fixed and empty amounts are copied verbatim.
- **Timers:** never scaled. Cooking time is not linear with yield. The
  authored amount is copied even when it would classify as scalable.
- Units, names, preparations, and `recipeRef` are never rewritten.
- References are still not merged.

The scaled view is not written into `graph.json` and does not bump
`schemaVersion`. `boris recipe-scale --input DIR --id PAGE --factor TEXT`
prints that view as a `boris-recipe-scale` JSON document on stdout
(and `--out PATH` when given). `--servings N` is the same command with
`factor = N / current`, where `current` is the page's `servings` count
or `1` when the key is absent. `--factor` and `--servings` are exclusive.
`--cooklang` is required for a `.cook` tree, same family rule as `build`.
Zero or unparsable factors / serving counts are a usage error. A missing
page, a refused Cooklang tree, or an overflowing amount is a content error.

Schema for one scaled amount:

```json
{ "class": "scalable", "original": "1/2", "scaled": "1" }
```

The page envelope is `docs/contracts/schemas/recipe-scale-view-0.1.0.schema.json`
(`format: boris-recipe-scale`). Timer `scaled` equals `original` even when
the amount classifies as scalable.

## IR version selection

The bump is conditional, exactly like the semantic-relations facet before it:

| Corpus carries | `schemaVersion` | `compiler` |
|---|---|---|
| neither facet | `0.2.0` | `boris/0.8.1` |
| semantic relations only | `0.3.0` | `boris/0.8.1+semantic-relations` |
| recipes | `0.4.0` | `boris/0.8.1+cooklang` |

`0.4.0` is a superset of `0.3.0`: a recipe corpus that also carries semantic
relations still emits `relations`. A corpus with no recipes is byte-identical to
before this slice existed, so adding Cooklang support is not a breaking IR
change.

## Known limitations

- **Graph diagnostics on a `.cook` page carry a fabricated locus.** They are
  located against the adapted Markdown, whose line numbering does not exist in
  the `.cook` file, so a broken `@./recipe` reference reports a line inside the
  synthesized ingredient list. Carrying the authored line through the adapter
  onto each `Ingredient` would fix it and is a follow-up, not this slice.
- **A diagnostic column after an inline comment is no longer approximate.**
  The old adapter deleted comment bytes before conversion, shifting later
  columns left. Oliver reports positions against the body it parsed, so both
  the seam's refusals and its degraded-structure warnings carry accurate
  columns. (The column a later graph diagnostic reports against the *adapted*
  Markdown is a different matter — see the first bullet.)
- A `.cook` body cannot express an inline Markdown image: `!` and `[` are
  escaped as author text. A recipe's sibling `<stem>.assets/` tree is still
  discovered and published, which matches Cooklang's own convention of naming
  pictures after the recipe rather than linking them inline.
- `--context` does not adapt non-Markdown bodies, so a context bundle for a
  `.cook` tree carries raw Cooklang source. This matches the existing Textile
  behaviour and is not changed here.
- ~~A raw U+2028 or U+2029 in an ingredient name reaches `graph.json`
  unescaped.~~ Fixed: `json_out.zig` now escapes the whole line-terminator class
  as `\uXXXX`, verified on a `.cook` ingredient name. U+0085 is refused earlier,
  at ingest, as a C1 control by `unicode_policy.zig`.
- Scaling, shopping-list aggregation, pantry files and `.menu` files are
  ecosystem conventions outside this slice.

## Fixtures

- [`fixtures/cooklang-compatibility/content/`](fixtures/cooklang-compatibility/content/)
  — a valid tree exercising every accepted construct, including a cross-recipe
  reference.
- [`fixtures/cooklang-compatibility/invalid/content/`](fixtures/cooklang-compatibility/invalid/content/)
  — refused input.
- [`fixtures/cooklang-compatibility/mixed/content/`](fixtures/cooklang-compatibility/mixed/content/)
  — a mixed-extension tree that must fail closed.
