### Added

- Cooklang recipe input via `--cooklang`, a `.cook`-only tree mode alongside
  `--textile`. Cooklang metadata is already YAML front matter, so Boris's
  frontmatter parser is unchanged and
  [`src/cooklang.zig`](/src/cooklang.zig) adapts only the body: ingredients,
  cookware, timers, sections, notes, both comment forms, short-hand
  preparations, and forced line breaks. The rendered document is an
  `## Ingredients` list, a `## Cookware` list, and `## Method` numbered steps.
  Author text is escaped against the engine Boris actually links — Oliver,
  CommonMark 0.31.2 (652/652 conformance) plus GFM tables and the opted-in
  heading-attribute, footnote, definition-list and strikethrough extensions.
  The per-byte set covers CommonMark's live punctuation (`|` table cells, `#`
  headings, `-`/`+` list items, `` ` `` code spans, `[`/`]` links, `=` setext
  underlines, `~` strikethrough) and the entity characters `&`, `<`, `>`
  against raw-HTML interpretation. A `"` guard survives from the old Apex
  path, where fenced divs emitted `class="…"` unescaped and
  `:::x"onmouseover="alert(1)` published `<div class="x"onmouseover="alert(1)">`;
  Oliver has no fenced divs, so that injection is closed by the renderer
  migration, but the guard is harmless under CommonMark and keeps the adapter
  engine-agnostic. Every author-controlled span is guarded, including token
  names, quantities, preparations and section names,
  and the bounded subset refuses macros, wiki links, raw HTML, control
  characters, unterminated `{`, `(` or `[-`, and over-long or over-numerous
  tokens with `ECOOKLANG`.
  A recipe reference (`@./sauces/pepper-oil{1%tbsp}`) becomes a real wiki link
  and therefore a validated graph edge of kind `reference`, so a reference to a
  recipe that does not exist fails the build instead of rendering as dead prose.
  The structured recipe reaches the IR as the `recipe` node facet — quantities
  stay strings because Cooklang admits `1/2` and `1-2`, and references are never
  merged because adding `200%g` to `1%cup` needs a unit model Boris does not
  have. Like semantic relations before it, the version bump is conditional:
  a corpus with no recipes still emits `0.2.0`, so existing artifacts do not
  move. Contract:
  [cooklang-compatibility.md](/docs/contracts/cooklang-compatibility.md);
  schema: [`ir-graph-0.4.0.schema.json`](/docs/contracts/schemas/ir-graph-0.4.0.schema.json);
  fixtures: [`fixtures/cooklang-compatibility/`](/docs/contracts/fixtures/cooklang-compatibility/).
