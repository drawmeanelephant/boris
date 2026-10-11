# Field Notes

**A bound expedition notebook: the site is the logbook, every page is an
entry on grid paper, and the index lists legs of the route.**

Not a documentation shell with a blue rule. Each leaf sits behind a punched
binding margin on faint grid paper; the entry header is a stamped field
block — the status arrives as a rotated rubber stamp (`{{page-status}}`),
and `{{metadata}}` prints as the entry's field line (STATUS · PARENT ·
TAGS · PUBLISHED). Children list as numbered log lines ("entry 01 … turn
to"), the site graph lives in the **Logbook index** margin column, and the
page outline is **Marginalia**. Serif prose, mono furniture, kraft cover
band. Dark mode is the same book read by headlamp.

System stacks only — ui-serif for prose, ui-monospace for field labels. No
dependencies, JavaScript, remote assets, or new author grammar. Reduced
motion disables smooth scrolling; print drops the cover band, margin
column, and binding furniture and keeps the entry.

- Layouts: `layouts/main.html`, `layouts/section.html`, `layouts/home.html`
- Stylesheet: [`assets/field-notes.css`](assets/field-notes.css)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Specimen: six Markdown entries embedded below (no extra starter files).
- Original sample (still supported): [field-notes-site on GitHub](https://github.com/drawmeanelephant/boris/tree/main/examples/field-notes-site/)

## Build the saltmarsh survey

The [embedded specimen](#specimen-entries) below is a complete content
tree: a logbook cover, a transect leg with two dated entries, a kit list,
and a running tally. Copy its six blocks to the named paths under a scratch
content directory. This checkout-only command extracts them without adding
a product build stage:

````bash
mkdir -p test-output/field-notes-personality/specimen/content/transects
awk -v root=test-output/field-notes-personality/specimen/content '
  /^### .*\.md$/ { path = $2 }
  !writing && path != "" && ($0 == "```markdown" || $0 == "````markdown") {
    fence = substr($0, 1, length($0) - 8); file = root "/" path; writing = 1; next
  }
  writing && $0 == fence { close(file); writing = 0; path = ""; next }
  writing { print > file }
' themes/field-notes/README.md
````

From a Boris checkout, compile that directory with the theme:

```bash
./zig-out/bin/boris \
  --input test-output/field-notes-personality/specimen/content \
  --theme themes/field-notes \
  --layout-rule default id:index themes/field-notes/layouts/home.html \
  --layout-rule default id:transects themes/field-notes/layouts/section.html \
  --html-dir test-output/field-notes \
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

- `home.html` is the cover leaf: the logbook's title entry, its field
  line, then **Legs of the route** — the numbered `{{children}}` lines —
  and **The whole logbook** disclosure for the rest of the graph. A
  childless cover simply shows no leg list.
- `section.html` is a leg of the route: same leaf and margin column, with
  the entries logged under this heading as the main content.
- `main.html` is one field entry: stamp and field line up top, prose body,
  more entries in the leg and cross-referenced entries at the foot, with
  the logbook index and marginalia in the right margin column.

`blog`, `archive`, and `print` are declined: a logbook is ordered by legs
and entries, not by a dated feed, and `@media print` already reduces every
layout to the leaf.

## Slot coverage

All three layouts retain `{{content}}`, `{{title}}` (spent on the document
`<title>`; the authored `h1` is the entry's headline), `{{nav}}`,
`{{breadcrumb}}` (printed on the cover band as the filed-under path),
`{{toc}}`, `{{children}}`, `{{metadata}}` (the entry's field line),
`{{relations}}`, `{{backlinks}}` ("See also" / "Cited in"), `{{head}}`,
`{{footer}}`, and `{{page-status}}` (twice: the stamp's text and its
`data-state`). `{{tags}}` and `{{parent}}` are intentionally absent: the
field line already prints Tags and Parent. Everything except the author
prose is excluded from rendered search.

## Specimen entries

The filenames below are relative to your scratch content root. They are
prose specimens — dated entries, a tally table, and callouts — not new
components or theme configuration. The transect leg selects `section.html`
via the build command above.

### index.md

```markdown
---
title: The saltmarsh survey
status: published
tags: [logbook, survey, june]
---

# Five days on the marsh. Written down as it happened.

This is the working logbook for the June transect survey: the walks, the kit, and the running tally. Entries were written in the field and transcribed the same evening.

Open a leg. The entries are short on purpose — a field note earns its page or it doesn't get one.
```

### transects.md

```markdown
---
title: Transect walks
parent: index
status: published
tags: [logbook, transects]
relations: [relates_to=tally]
---

# Transect walks

One leg of the route per day: the same 400-meter line at low tide, walked slowly, written up before dinner.

## The line

Grid reference TQ 826 041 to TQ 830 045, following the creek's north bank. Marked at 25-meter intervals; counts taken within two meters either side.

<Aside kind="note">

Low tide windows this week: 06:40, 07:15, 08:05, 08:50, 09:30. Miss the window and the mud wins.

</Aside>
```

### transects/day-one.md

```markdown
---
title: "Day one — overcast, light NE wind"
parent: transects
status: published
tags: [entry, transects]
relations: [depends_on=kit]
---

# Day one — overcast, light NE wind

06:40 at the start marker. Air 14°C, water cold enough to notice through the boots.

## Counts

| Quadrat | Samphire | Sea aster | Cordgrass |
|---|---|---|---|
| 1–4 | dense | scattered | none |
| 5–8 | patchy | dense | 2 clumps |
| 9–12 | sparse | dense | 6 clumps |
| 13–16 | none | scattered | dense |

## Notes

Two curlew working the creek edge the whole way. The boardwalk at marker 9 is loose — flagged it with tape and noted for the wardens.

<Aside kind="tip">

Write the quadrat numbers before you crouch down. Kneeling in mud with an open notebook is how pages get lost.

</Aside>
```

### transects/day-two.md

```markdown
---
title: "Day two — clearing, wind swung west"
parent: transects
status: published
tags: [entry, transects]
relations: [relates_to=transects/day-one]
---

# Day two — clearing, wind swung west

07:15 start, better light. Ran the same line back the other way to check yesterday's cordgrass count.

## What changed

Cordgrass clumps 13–16 confirmed, plus one more at 15b I'd walked past. Sea aster is further along than yesterday suggested — the patchy areas are filling in.

## Sketch

```text
creek ──────────────────────────► flow
TQ826  ···· samphire bench ···· TQ828
            ↓ 2m
       aster band, widening
```

> If the aster keeps filling at this rate, next June's leg two will be a different walk.
```

### kit.md

````markdown
---
title: The kit list
parent: index
status: published
tags: [logbook, kit]
relations: [relates_to=tally]
---

# The kit list

What actually earned its weight. Everything else stayed in the truck.

## In the bag

- Weatherproof notebook, 2 pencils (pens fail wet)
- 25-meter tape, quadrat frame
- Flagging tape, two colors
- Phone for the grid reference, kept in the dry pocket

## Left behind

- The field guide — too heavy; tally goes in the notebook and identification happens at the table.
- Spare camera battery — the light never lasted long enough to need it.

<Aside kind="warning">

Cotton trousers were a mistake on day one. The marsh keeps what it brushes against.

</Aside>
````

### tally.md

```markdown
---
title: The running tally
parent: index
status: published
tags: [logbook, tally]
relations: [depends_on=transects]
---

# The running tally

Counts roll up here at the end of each day. The notebook gets numbers; the table at home gets the spreadsheet.

| Species | Day 1 | Day 2 | Trend |
|---|---|---|---|
| Samphire | 41 | 39 | holding |
| Sea aster | 88 | 104 | filling in |
| Cordgrass | 9 | 10 | creeping up-bank |
| Curlew | 2 | 1 | — |

## Method note

Counts are presence within two meters of the line, not absolute density. Compare like with like: same line, same tide window, same walker.
```
