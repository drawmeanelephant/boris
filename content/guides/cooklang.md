---
title: CookLang Recipes
parent: guides
status: published
tags: [guides, cooklang, recipes]
summary: The .cook-only recipe mode — whole-tree adapter, structured ingredient/cookware/timer data in the IR, and compiler-owned recipe-scale views.
---

<p class="eyebrow">Intake</p>

# CookLang Recipes {#cooklang-recipes}

CookLang is a plain-text recipe format: prose steps with sigils that make
ingredients, cookware, timers and durations machine-parsable. Boris's
`--cooklang` input adapter is **an adapter into Boris, not a Cooklang
implementation and not a second site compiler**. You write `.cook` files,
Boris renders them through the normal pipeline, and the structured data —
not just the prose — reaches the IR as the `recipe` node facet.
`boris recipe-scale` then derives scaled views without rewriting the source.

The normative surface is the
[cooklang-compatibility contract](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/cooklang-compatibility.md).
This page is the teaching trail; the contract wins.

## Whole-tree mode: `.cook` only {#whole-tree}

`--cooklang` is an **input-format modifier**: with it, discovery accepts
lowercase `.cook` files only. Without it, discovery accepts lowercase `.md`
and `.mdx` only.

- A tree mixing `.cook` with any other page extension fails with `ECOOKLANG`.
  Boris never guesses a dialect per page.
- A `.cook`-only tree invoked **without** `--cooklang` — or a Markdown tree
  invoked with it — fails the same way with a mode-selection remediation.
- Extensions are case-sensitive: `.COOK` is not a page.
- `--cooklang` and `--textile` together are a usage error: each is a
  whole-tree mode that refuses the other's extension.

That is why recipes live in their own content root, e.g. `recipes/` beside a
Markdown `content/`:

```text
content/    your site (Markdown)
recipes/    your recipes (.cook only)
```

## Frontmatter is still Boris frontmatter {#frontmatter}

The adapter **never parses metadata**: Boris splits the frontmatter from the
original source bytes first, and only the body is adapted. The closed
[[reference/frontmatter|frontmatter grammar]] therefore applies unchanged —
`id`, `title`, `parent`, `status`, `tags`, `relations`, `published_at`,
`summary`, plus the Cooklang-convention **`servings`** exception (`serves`
and `yield` are aliases for that one key). Every other Cooklang metadata name
(`source`, `author`, `course`, `time`, …) is `EFRONTMATTER`. `parent`,
`tags`, and semantic relations behave exactly as they do for a Markdown page.

```cooklang
---
title: Dolly Parton's Coleslaw
parent: recipes
status: published
tags: [recipes, coleslaw]
servings: 10
summary: Pickle juice adds a special tang.
---

> Pickle juice adds a special tang to Dolly's delicious coleslaw.

Chop @cabbage{1%medium head} and place in a large #bowl{}.

Sprinkle @sugar{2%tsp}, @black pepper{0.25%tsp}, and @salt{1%tsp}.
```

## Accepted syntax {#syntax}

Boris accepts a closed subset of the
[Cooklang specification](https://cooklang.org/docs/spec/):

| Construct | Source | Effect |
|---|---|---|
| Ingredient, one word | `@salt` | Name ends at whitespace or sentence punctuation |
| Ingredient, multi-word | `@ground black pepper{}` | Name ends at `{`, which must touch the name |
| Quantity | `@potato{2}` | amount = `2` |
| Quantity with unit | `@bacon{1%kg}` | amount = `1`, unit = `kg` |
| Preparation | `@onion{1}(peeled)` | preparation = `peeled` |
| Recipe reference | `@./sauces/pepper-oil{1%tbsp}` | `recipeRef`; the `./` prefix is required |
| Cookware | `#pot`, `#potato masher{}` | recorded in `cookware` |
| Timer, anonymous | `~{25%minutes}` | renders as `25 minutes` |
| Timer, named | `~eggs{3%minutes}` | name = `eggs`, for app notifications |
| Step | paragraph | one numbered Method item |
| Forced break | trailing `\` | CommonMark hard break |
| Note | `> text` | Markdown blockquote |
| Section | `= Dough`, `== Filling ==` | `###` heading inside Method; numbering restarts |
| Line comment | `-- text` | removed |
| Block comment | `[- text -]` | removed, may span lines |

The brace rules are load-bearing. A multi-word name must be closed with `{`,
and that `{` **must touch the name** — `add @salt into the {bowl}` reads
`salt into the` as the name and `bowl` as its amount, deleting the prose
between them from the rendered step. The lookahead also stops at another
sigil (`@`, `#`, `~`) or a bracket, so `add @salt and @pepper{1}` reads two
ingredients.

## Recipe references become graph edges {#references}

`@./sauces/pepper-oil{1%tbsp}` renders in the ingredient list as a Boris wiki
link (`[[sauces/pepper-oil]]`). That is deliberate: the reference becomes a
validated graph edge of kind `reference`, so referencing a recipe that does
not exist fails the build instead of rendering dead prose. The `./` prefix is
required, and the derived id must satisfy Boris's entity-id grammar before it
is emitted.

## What renders {#rendered}

The rendered page has a fixed, deterministic shape:

1. **Ingredients** — one bullet per reference, with `— amount unit` and
   `(preparation)` when present.
2. **Cookware** — one bullet per cookware reference.
3. **Method** — steps as an ordered list; author sections as `###` headings;
   notes as blockquotes.

An empty group is omitted entirely rather than rendered as an empty heading.
Within a step, ingredient and cookware names render inline and a timer
renders as its duration, so the prose reads as a sentence; quantities live in
the ingredient list, where a cook reads them.

## Build and validate {#build}

```bash
./zig-out/bin/boris validate --input recipes --cooklang --quiet   # zero-write preflight
./zig-out/bin/boris build --input recipes --cooklang --theme themes/lab --quiet
```

`--cooklang` composes with the normal output selectors — HTML (`--html-dir`,
`--target`, `--theme`, layouts), IR (`--out`), RAG, `check`, `impact`,
`incremental`, `watch`, and `-j` page workers. Output lands wherever you point
it (default `dist/`). Recipes participate in the same graph, search, and
evidence machinery as Markdown pages.

<Aside kind="note" id="warnings-vs-refusals">

Malformed structure degrades to literal text with a structured warning and
the build still exits `0` (`unclosed-braces`, `unclosed-preparation`,
`unclosed-block-comment`, `unclosed-frontmatter`). Hard refusals — control
characters, a timer with neither name nor duration, a nameless section, an
invalid recipe reference, an over-long token name — fail with `ECOOKLANG`.

</Aside>

## Scale a recipe {#scale}

`boris recipe-scale` is read-only: it never rewrites `.cook` files or
`graph.json`.

```bash
./zig-out/bin/boris recipe-scale --input recipes --cooklang --id coleslaw --factor 2
./zig-out/bin/boris recipe-scale --input recipes --cooklang --id coleslaw --servings 6
./zig-out/bin/boris recipe-scale --input recipes --cooklang --id coleslaw --factor 2 --out scale.json
```

- `--factor TEXT` accepts `2`, `1/2`, `1.5`, `1 1/2`; `--servings N` computes
  `factor = N / current`, where `current` is the page's `servings` count or
  `1` when the key is absent. The two flags are exclusive.
- Ingredients and cookware are scaled as exact rationals. A decimal-family
  result emits a terminating decimal (`1.5 × 3 = 4.5`); anything else emits a
  reduced `num/den`.
- **Timers are never scaled** — cooking time is not linear with yield. Each
  timer carries `"scaling": "locked"` so the unchanged amount is
  self-describing rather than looking like a bug.
- Fixed and empty amounts (ranges like `1-2`, words like `some`) are copied
  verbatim; overflow leaves the authored amount unchanged.
- References are never merged: two `@flour` references stay two entries.

The output is a `boris-recipe-scale` JSON document (schema 0.2.0) on stdout
or `--out PATH`. One scaled amount looks like:

```json
{ "class": "scalable", "original": "1/2", "scaled": "1" }
```

The [[guides/editor#cooklang-recipes|Boris Editor]] shows a recipe's
ingredients, cookware, and timers from the compiler facet, and its **Scale
recipe** button runs exactly this command.

## The recipe IR facet {#ir}

Once any page in the corpus carries a recipe, every `graph.json` node carries
a `recipe` facet (`null` for pages that do not), and the IR version bumps to
`0.4.0` (`boris/0.8.1+cooklang`). Two properties are contractual:

- **Quantities are strings.** Cooklang admits `2`, `1/2`, `1.5`, `1-2`, and
  bare words like `some`; the IR keeps what the author wrote. Scaling is a
  separate, compiler-owned operation over those strings.
- **References are never merged.** Each list holds one entry per reference in
  authored order, so a consumer that wants a combined shopping list can group
  them and one that wants fidelity has it. `recipeRef` is an entity id,
  joinable against `nodes[].id`, so a consumer can follow a sub-recipe
  without re-parsing an ingredient name.

The facet is bounded by contract: 512 ingredients, 128 cookware items, 128
timers, and 256-byte token names.

## Known limitations {#limits}

- **Graph diagnostics on a `.cook` page carry a fabricated locus.** They are
  located against the adapted Markdown, so a broken `@./recipe` reference may
  report a line inside the synthesized ingredient list rather than in the
  `.cook` file.
- A `.cook` body cannot express an inline Markdown image (`!` and `[` are
  escaped as author text). A recipe's sibling `<stem>.assets/` tree is still
  discovered and published — matching CookLang's own picture convention.
- `--context` does not adapt non-Markdown bodies, so a context bundle for a
  `.cook` tree carries raw CookLang source.
- Scaling, shopping-list aggregation, pantry files, and `.menu` files are
  ecosystem conventions outside this slice.

## Next steps

- [[reference/frontmatter|Frontmatter Reference]] — the closed key set and the `servings` exception
- [[reference/commands|Command Reference]] — `recipe-scale` and exit codes
- [[guides/editor|Boris Editor]] — the compiler-backed authoring surface, including the Recipe pane
- [[guides/building-pages|Building Pages]] — pages, links, and includes for Markdown trees
- [[guides/migration|Migrating to Boris]] — intake from other content shapes
