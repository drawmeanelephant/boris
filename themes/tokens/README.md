# Tokens

**A token sheet for a design system: every page is a spec sheet, every family
is a register of named values, and the chrome shows the tokens it runs on.**

Not a documentation shell with a purple accent. Sheets carry hairline rules
and spec tables instead of hero cards; page metadata prints as sheet fields
(`STATUS = published`); generated children list as numbered register entries;
the site graph folds into a catalog column. The masthead carries the actual
swatch strip — every chip is a live `var(--…)` from the stylesheet — and the
cover adds the working set: swatches, type steps, and space bars drawn from
the same tokens. A draft sheet gets a dashed border and a DRAFT stamp. Dark
mode prints the same set as a blueprint.

System font stacks only (sans for prose, mono for sheet furniture). No
dependencies, JavaScript, remote assets, or new author grammar. Reduced
motion disables smooth scrolling; print removes the masthead, catalog, and
register chrome and keeps the sheet.

- Layouts: `layouts/main.html`, `layouts/section.html`, `layouts/home.html`
- Stylesheet: [`assets/css/tokens.css`](assets/css/tokens.css)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Specimen: six Markdown sheets embedded below (no extra starter files).
- Previous shared sample (still supported): [studies-site on GitHub](https://github.com/drawmeanelephant/boris/tree/main/examples/studies-site/)

## Build the house set

The [embedded specimen](#specimen-sheets) below is a complete content tree:
a catalog cover, a color set with two sheets, a type sheet, and a space
sheet. Copy its six blocks to the named paths under a scratch content
directory. This checkout-only command extracts them without adding a product
build stage:

````bash
mkdir -p test-output/tokens-personality/specimen/content/color
awk -v root=test-output/tokens-personality/specimen/content '
  /^### .*\.md$/ { path = $2 }
  !writing && path != "" && ($0 == "```markdown" || $0 == "````markdown") {
    fence = substr($0, 1, length($0) - 8); file = root "/" path; writing = 1; next
  }
  writing && $0 == fence { close(file); writing = 0; path = ""; next }
  writing { print > file }
' themes/tokens/README.md
````

From a Boris checkout, compile that directory with the theme:

```bash
./zig-out/bin/boris \
  --input test-output/tokens-personality/specimen/content \
  --theme themes/tokens \
  --layout-rule default id:index themes/tokens/layouts/home.html \
  --layout-rule default id:color themes/tokens/layouts/section.html \
  --html-dir test-output/tokens \
  --quiet
```

For an arbitrary tree the usual recipe is `id:index` → `home.html` plus
`role:trunk` → `section.html` (the exact-id rule wins on the index). Keeping
the specimen in this README leaves the shared examples untouched; the
commands above are for a Boris checkout and are not starter-relative links.

For live preview, use the same arguments with `boris watch --serve
--port 8090` instead of a one-shot build, then open the printed loopback
URL. The built-in `/__boris/` helper reloads after successful edits; the
published site stays JavaScript-free.

## Named layouts

- `home.html` is the cover sheet: intro prose and spec fields, the working
  set band (live swatches, `Aa` steps, space bars drawn from `:root`), then
  the register of `{{children}}` and a **Full catalog index** disclosure for
  the rest of the graph. A childless cover simply shows no register.
- `section.html` is the set index: the same sheet shape with the register as
  its main content, plus the catalog column on the left.
- `main.html` is one token sheet: spec fields up top, prose body, register
  and cross-references at the foot, catalog and sheet contents in the left
  index column.

`blog`, `archive`, and `print` are declined: a token set is a stable
reference, not a dated feed, and `@media print` already reduces every layout
to the sheet.

## Slot coverage

All three layouts retain `{{content}}`, `{{title}}` (spent on the document
`<title>`; the authored `h1` is the sheet's headline), `{{nav}}`,
`{{breadcrumb}}`, `{{toc}}`, `{{children}}`, `{{metadata}}`, `{{relations}}`,
`{{backlinks}}`, `{{head}}`, `{{footer}}`, and `{{page-status}}` (on the
sheet element, driving the draft stamp). `{{tags}}` and `{{parent}}` are
intentionally absent: the spec table already prints Tags and Parent, and the
sheet path already links the parent. Everything except the author prose is
excluded from rendered search.

## Specimen sheets

The filenames below are relative to your scratch content root. They are
prose specimens — the swatches and bars are ordinary Markdown tables and
raw-HTML spans, not new components or theme configuration. The color set
selects `section.html` via the build command above.

### index.md

```markdown
---
title: The house set
status: published
tags: [tokens, catalog]
---

# One set of names. Every page agrees.

A token is a name that holds a value, so two things that should match always do. This is the working set for one small product — color, type, and space, kept in three sheets.

The values on each sheet are the ones this site is actually using. If a value is not named here, it does not ship.
```

### color.md

````markdown
---
title: The color set
parent: index
status: published
tags: [tokens, color]
relations: [relates_to=type]
---

# The color set

Nine names carry the whole palette. Light mode is paper; dark mode prints the same set as a blueprint.

## The reading pair

| Token | Value | Swatch | Job |
|---|---|---|---|
| `--ink` | `#22201b` | <span class="sw" style="background:#22201b"></span> | All reading text |
| `--sheet` | `#fffef9` | <span class="sw" style="background:#fffef9"></span> | The sheet surface |
| `--paper` | `#efece2` | <span class="sw" style="background:#efece2"></span> | The desk behind the sheet |
| `--accent` | `#b0431f` | <span class="sw" style="background:#b0431f"></span> | Links and marks, nothing else |

## Rules of the set

1. Text sits on `--sheet` or `--paper`, never on a signal color.
2. `--accent` is for links and the odd rule of emphasis. It is not a fill.
3. A new color earns a name or it does not exist.

Signals live on [their own sheet](color/signal.md); the reading pair's numbers are on [ink on paper](color/ink-paper.md).
````

### color/ink-paper.md

```markdown
---
title: Ink on paper
parent: color
status: published
tags: [tokens, color, contrast]
relations: [relates_to=color/signal]
---

# Ink on paper

`--ink` on `--sheet` is the only pairing allowed to carry a paragraph. It measures 14.3:1 — nearly triple the floor.

## Where each ink goes

| Token | Use |
|---|---|
| `--ink` | Body text, headings, the current entry in the catalog |
| `--ink-soft` | Labels, field names, crumbs, register numbers |

`--ink-soft` is for furniture, not sentences. It measures 4.8:1 — fine at label size, wrong for prose.

<Aside kind="tip">

Check a pairing by reading a whole paragraph, not a word. A bold label can pass where body text fails.

</Aside>
```

### color/signal.md

```markdown
---
title: Signal colors
parent: color
status: published
tags: [tokens, color, callouts]
relations: [depends_on=color/ink-paper]
---

# Signal colors

Four kind tokens mark intent. They draw the edge and the label of a callout — never the background of a page.

| Token | Value | Swatch | Says |
|---|---|---|---|
| `--note` | `#2b5f8a` | <span class="sw" style="background:#2b5f8a"></span> | Worth knowing |
| `--tip` | `#2f6b4f` | <span class="sw" style="background:#2f6b4f"></span> | Do it this way |
| `--warn` | `#8a5a00` | <span class="sw" style="background:#8a5a00"></span> | Check before you ship |
| `--danger` | `#a02515` | <span class="sw" style="background:#a02515"></span> | This bites |

<Aside kind="warning">

A signal is a sentence, not a style. If everything is marked, nothing is.

</Aside>
```

### type.md

````markdown
---
title: The type scale
parent: index
status: published
tags: [tokens, type]
relations: [relates_to=space]
---

# The type scale

Five steps. Prose lives at `--step-0`; the scale runs up from there and down exactly once.

## The steps, at size

| Token | Size | Specimen |
|---|---|---|
| `--step-4` | 2.8rem | <span style="font-size:2.8rem;font-weight:800;line-height:1">Ag</span> |
| `--step-3` | 2rem | <span style="font-size:2rem;font-weight:800;line-height:1">Ag</span> |
| `--step-2` | 1.5rem | <span style="font-size:1.5rem;font-weight:700;line-height:1">Ag</span> |
| `--step-1` | 1.22rem | <span style="font-size:1.22rem;font-weight:700;line-height:1">Ag</span> |
| `--step-0` | 1rem | <span style="font-size:1rem">The sheet is the site.</span> |
| `--step--1` | 0.82rem | <span style="font-size:0.82rem">Sheet furniture reads small on purpose.</span> |

## Two faces

```text
--sans  prose, headings, register titles
--mono  token names, labels, fields, numbers
```

If a line of text names a value, it is mono. Everything else is sans. There is no third face.
````

### space.md

```markdown
---
title: Space and rhythm
parent: index
status: published
tags: [tokens, space]
---

# Space and rhythm

Eight steps, one base. Everything on a sheet lands on the scale or it does not land at all.

## The first four working steps

| Token | Value | Bar |
|---|---|---|
| `--s-4` | 1rem | <span class="sw" style="display:inline-block;width:1rem;height:0.7rem;background:var(--accent,#b0431f)"></span> |
| `--s-5` | 1.5rem | <span class="sw" style="display:inline-block;width:1.5rem;height:0.7rem;background:var(--accent,#b0431f)"></span> |
| `--s-6` | 2rem | <span class="sw" style="display:inline-block;width:2rem;height:0.7rem;background:var(--accent,#b0431f)"></span> |
| `--s-7` | 3rem | <span class="sw" style="display:inline-block;width:3rem;height:0.7rem;background:var(--accent,#b0431f)"></span> |

## Rhythm rules

- Inside a component: `--s-1` through `--s-3`.
- Between blocks on a sheet: `--s-4` and `--s-5`.
- Between sections: `--s-6` and up.

<Aside kind="note">

Corners stay square. `--radius` is not in this set — a spec sheet has edges.

</Aside>
```
