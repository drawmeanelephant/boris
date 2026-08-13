# Bounded Cooklang recipe input adapter

**Status:** normative, additive input compatibility slice
**CLI selector:** `--cooklang`
**Adapter identity:** `boris-cooklang-adapter-v1`
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
the body is adapted. `id`, `title`, `parent`, `tags` and semantic relations
behave exactly as they do for a Markdown page.

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
  -> include expansion, wiki rewrite, Aside tokenization, Apex  (unchanged)
```

- The adapter is pure: no filesystem, Apex, layout, graph, or process access.
- Adaptation is total and deterministic; the same body always produces the same
  Markdown and the same `Recipe`.
- **Adapter** diagnostic lines and columns refer to the author's `.cook` file.
  Comment removal preserves every newline so a payload inside a block comment
  cannot shift the line a later error reports, and the column is compensated for
  stripped leading indentation.
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
fails the build instead of rendering as dead prose. The adapter emits Boris
syntax here; author-written `[[` is still refused (below).

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

Recipe prose is untrusted input, and the escape set is derived from **the engine
Boris links, not from CommonMark**. `apex_options_default` enables tables,
footnotes, definition lists, math, critic markup, attributes, callouts, fenced
divs, spans and marked extensions, so characters that are inert in CommonMark
are live here. Deriving the set from CommonMark produced a real event-handler
injection: a fenced div emits its class into `class="…"` unescaped, so
`:::x"onmouseover="alert(1)` on a step continuation line published
`<div class="x"onmouseover="alert(1)">`.

| Character | Treatment | Why |
|---|---|---|
| `&` `<` `>` `"` | entity | `"` delimits an attribute value |
| `` \ ` * _ { } [ ] # + - ! | ~ ^ = $ `` | backslash | block and inline constructs, incl. `^` superscript, `==highlight==`, `$math$` |
| `:` at the start of a line | `&#58;` | opens a fenced div (`:::`) or a definition list (`: term`) |
| `:` adjacent to another `:` | `&#58;` | `term :: definition` is a definition list **anywhere** on a line |
| `:` elsewhere | passed through | opens nothing mid-sentence, and escaping every one would litter the corpus |
| digits then `.` or `)` at line start | backslash | an ordered-list marker would nest a list inside the step |

Two details are load-bearing and were measured against the engine rather than
assumed:

- Definition lists and fenced divs are **text preprocessors that run before
  parsing**, so a backslash escape never reaches them. `&#58;::x` still opened a
  fenced div because the literal `::` survived; a numeric character reference
  leaves no literal colon to find.
- Colon adjacency is judged against the **output** buffer, not the input span. A
  pair can be assembled across two spans where neither half can see it:
  `Mix @salt:{1}: done` emitted `salt:` from the ingredient name and `:` from
  the following prose, producing `Mix salt:: done`.

Every author-controlled span is guarded, not just step prose: a token name, a
`{quantity}`, a `(preparation)` and a section name all reach published output.

The adapter fails the build with `ECOOKLANG` on:

- `{{ … }}` macros, `[[ … ]]` wiki links, and raw HTML or components
- control characters other than tab
- an unterminated `{`, `(`, or `[-`
- a nested `{` in a quantity or `(` in a preparation
- an empty ingredient or cookware name, so a bare `#` or `@` is an authoring
  error rather than silent literal text
- a timer with neither a name nor a duration, including `~{}`
- a section with no name between its `=` markers
- a recipe reference that is not a valid page id (below)
- a token name longer than `max_token_name_bytes`, or more than
  `max_ingredient_count` / `max_cookware_count` / `max_timer_count` items

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
words like `some`. Converting to a number would either reject valid recipes or
silently round them, so the compiler keeps what the author wrote and leaves
arithmetic to a consumer. Scaling is not in this slice.

**References are never merged.** Each list holds one entry per reference in
authored order. Merging two `@flour` references means adding `200%g` to `1%cup`,
which is not decidable without a unit model. A consumer that wants a combined
shopping list can group these; a consumer that wants fidelity has it.

`recipeRef` is an entity id, joinable against `nodes[].id`, so a consumer can
follow a sub-recipe without re-parsing an ingredient name.

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
- **A diagnostic column after an inline comment is approximate.** Comment bytes
  are deleted before conversion, which shifts later columns left. Leading
  indentation is compensated; an inline `[- … -]` is not.
- A `.cook` body cannot express an inline Markdown image: `!` and `[` are
  escaped as author text. A recipe's sibling `<stem>.assets/` tree is still
  discovered and published, which matches Cooklang's own convention of naming
  pictures after the recipe rather than linking them inline.
- `--context` does not adapt non-Markdown bodies, so a context bundle for a
  `.cook` tree carries raw Cooklang source. This matches the existing Textile
  behaviour and is not changed here.
- A raw U+2028 or U+2029 in an ingredient name reaches `graph.json` unescaped.
  This is a pre-existing property of `json_out.zig` shared with every other
  emitter — a Markdown `title` reaches the identical escaper — so the recipe
  facet adds a field but no new capability. Fixed separately. (U+0085 is already
  refused at ingest as a C1 control by `unicode_policy.zig`.)
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
