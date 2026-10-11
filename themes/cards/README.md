# Cards

**An index-card workbench for useful things: deal out a collection, pull one
idea to read, and follow the thread to the next card.**

Not a documentation shell with rounder corners. Collections occupy the desk;
individual pages become tabbed, stacked sheets. Numbered, ruled cards make the
generated child list the main invitation to explore. The full graph lives in a
native **Open the index** drawer, and the page outline folds under **Find a
line**. No sidebar, permanent outline rail, hero-card wrapper, or badge strip.

Hand-authored local CSS and system fonts. No dependencies, JavaScript, remote
assets, filtering, drag-and-drop, or new author grammar. Light and dark desk
palettes follow the operating system; reduced motion disables card lift
transitions. Print removes the desk furniture.

- Layouts: `layouts/main.html`, `layouts/home.html`
- Stylesheet: [`assets/css/cards.css`](assets/css/cards.css)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Specimen: six Markdown cards embedded below (no extra starter files).
- Original sample (still supported): [cards-site on GitHub](https://github.com/drawmeanelephant/boris/tree/main/examples/cards-site/)

## Build the useful-things box

The [embedded specimen](#specimen-cards) below is a complete content tree.
Copy its six blocks to the named paths under a scratch content directory. This
checkout-only command extracts them without adding a product build stage:

````bash
mkdir -p test-output/cards-personality/specimen/content/foundations
awk -v root=test-output/cards-personality/specimen/content '
  /^### .*\.md$/ { path = $2 }
  !writing && path != "" && ($0 == "```markdown" || $0 == "````markdown") {
    fence = substr($0, 1, length($0) - 8); file = root "/" path; writing = 1; next
  }
  writing && $0 == fence { close(file); writing = 0; path = ""; next }
  writing { print > file }
' themes/cards/README.md
````

From a Boris checkout, compile that directory with the theme:

```bash
./zig-out/bin/boris \
  --input test-output/cards-personality/specimen/content \
  --theme themes/cards \
  --layout-rule default id:index themes/cards/layouts/home.html \
  --layout-rule default id:foundations themes/cards/layouts/home.html \
  --html-dir test-output/cards \
  --quiet
```

The specimen is a working box of six cards: a collection index, a working-notes
file, two practical notes, a commonplace card, and a house recipe. It demonstrates
the theme rather than describing a generic documentation layout. Keeping it in
this README leaves the other themes' shared examples untouched and preserves
`boris init`'s byte-identical theme-file handoff. The commands above are for a
Boris checkout; none is a starter-relative link to a missing repository file.

For live preview, use the same arguments with `boris watch --serve --port 8090`
instead of a one-shot build, then open the printed loopback URL. The built-in
`/__boris/` helper reloads after successful edits; the published site stays
JavaScript-free.

## Named layouts

- `home.html` spreads a collection across the desk: unboxed title and intro,
  then a numbered `{{children}}` deck. Use it for the site index and collection
  hubs via the existing `--layout-rule` interface. A childless collection simply
  shows its prose; it never displays an empty deck.
- `main.html` pulls a single sheet out of the box. It centers readable prose,
  folds the outline at the top, and files metadata at the bottom. If it has
  children, their deck follows the sheet. This remains the default, including
  for existing intermediate pages that have no named-layout rule.

The cookbook starter's existing home rule works unchanged. Recipe titles are
real generated child links, not hand-kept card markup. Cards also works on a
single-page link-in-bio or an image-rich page, but it is not a gallery-grid theme.

`section`, `blog`, `archive`, and `print` are declined: collection and single-card
views cover this voice without introducing a date feed or another hierarchy.

## Slot coverage

Both layouts retain `{{content}}`, `{{title}}`, `{{nav}}`, `{{breadcrumb}}`,
`{{toc}}`, `{{children}}`, `{{metadata}}`, `{{relations}}`, `{{backlinks}}`,
`{{footer}}`, and `{{head}}`. `{{page-status}}` carries the existing status on
the reading sheet or intro; status stays visible as text in the filing record.
Relations are filed alongside; backlinks show where other cards refer here.
All navigation, outlines, decks, filing records, and graph links are excluded
from rendered search; only the author prose is indexed.

`{{tags}}` and `{{parent}}` are intentionally absent: the metadata record already
shows Tags, and the breadcrumb already links the parent. No duplicated chips or
parent link. Card numbers indicate position in the compiler's deterministic
child list, not entity ids or a new ordering field.

## Specimen cards

The filenames below are relative to your scratch content root. They are prose
specimens, not new components or theme configuration. The two collection hubs
select `home.html` in the build command above. Markdown links are resolved by
Boris; no specimen links are hardcoded in the theme layouts.

### index.md

```markdown
---
title: The useful-things box
status: published
tags: [collection, keepers]
---

# Small things.<br>Worth keeping.

A recipe you actually make. A trick that saves an afternoon. An idea you want to come back to. Give it a card, not a feed.

Pull something from the box. Leave with something you can use.
```

### foundations.md

```markdown
---
title: Ways of working
parent: index
status: published
tags: [collection, practice]
---

# Less system.<br>More doing.

Small habits for getting a good thing out of your head and into the world. No productivity empire required.

These are working notes, not commandments. Pull a card. Try it once. Keep what earns its space.
```

### foundations/contrast.md

```markdown
---
title: The ten-minute reset
parent: foundations
status: published
tags: [practice, attention]
relations: [relates_to=patterns]
---

# The ten-minute reset

When everything feels equally urgent, stop rearranging the whole day. Make room for one useful thing.

## Clear a corner

1. Put the loose papers in one pile. Do not sort them.
2. Close every window except the one you need next.
3. Write one sentence: **Before I stop, I will have…**
4. Set a timer for ten minutes. Start badly if you have to.

<Aside kind="tip">

Name an outcome you can point at: a sent reply, a sketched screen, a paragraph. “Work on the project” does not fit on this card.

</Aside>

## Leave a breadcrumb

When the timer ends, write the next physical action. Not a strategy. An action.

> Open the draft. Replace the first sentence.

Tomorrow-you deserves a place to start, not another mystery to solve.
```

### foundations/one-card.md

````markdown
---
title: One card, one idea
parent: foundations
status: published
tags: [writing, practice]
---

# One card, one idea

A card is small on purpose. It asks you to decide what belongs together before you file it away.

## Give it a handle

A title should help you find the idea when you need it. “The ten-minute reset” beats “Some thoughts about productivity”.

```text
Name the thing.
Say when it helps.
Show how to do it.
Stop.
```

## Let the box do the organizing

Put related cards in a collection. Link to another card when the thought continues there. You do not need to squeeze the whole subject onto one sheet.

Start with [the ten-minute reset](contrast.md). The next ten minutes are enough.
````

### patterns.md

```markdown
---
title: Things worth noticing
parent: index
status: published
tags: [observations, keepers]
---

# Things worth noticing

Not every card is an instruction. Some are just a way to keep a good observation from disappearing.

## A small collection of handles

| Keep this | For when |
|---|---|
| Make the next step smaller. | You keep postponing it. |
| Leave a little unfinished. | You need a way back in tomorrow. |
| Keep the useful version. | You are polishing past the point of care. |

## The test of a keeper

Would you send it to a friend? Would you use it next week? Can you explain it without opening six other tabs?

<Aside kind="note">

The box is not a museum of everything you have ever read. It is a working collection. A card can leave when it stops helping.

</Aside>

Try [the ten-minute reset](foundations/contrast.md) before inventing a new system.
```

### recipes.md

```markdown
---
title: The house dressing
parent: index
status: published
tags: [kitchen, keeper]
---

# The house dressing

One jar. Five minutes. A reason to eat the leaves in the fridge.

## Into the jar

| Ingredient | Amount |
|---|---|
| Olive oil | 3 tablespoons |
| Lemon juice | 1 tablespoon |
| Dijon mustard | 1 teaspoon |
| Honey | 1 teaspoon |
| Salt | A generous pinch |

## Shake, taste, repeat

Close the lid and shake until cloudy. Taste on a leaf, not a spoon. Add lemon if it feels flat; oil if it bites.

<Aside kind="tip">

Double it for tomorrow. Keep it chilled and shake again before using.

</Aside>

The useful recipe is the one you remember. Three parts oil, one part acid, something sharp, something sweet.
```
