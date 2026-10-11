# Columns

A broadsheet. The site is a small daily: the index is the front page,
trunks are desks, satellites are stories, and every article is set in
justified columns with a rule between them — the name finally describes
the layout, not a CSS class.

- The masthead runs a nameplate, an edition line that carries the
  breadcrumb trail, and a sections bar (the site graph) in gothic caps.
- Each page opens with a rubric and a credit line (`{{metadata}}` as
  `STATUS · FILED UNDER · TAGGED`), and `{{page-status}}` prints as a
  rotated press stamp — `draft` marks in red like a prepress proof.
- Article prose flows in `columns: 21rem` with hairline column rules,
  hyphenated justification, and a drop cap on the first paragraph.
  Headlines span all columns the way a hed crosses the page.
- Children list as numbered story jumps (`Nº 01 … filed`). Relations are
  "Related stories"; backlinks are "Picked up by".
- Dark mode is the late city edition. Print keeps the columns and drops
  the press furniture.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

## Specimen

The specimen is one edition of a harbour paper — front page, a desk,
two stories, tide tables, and a draft corrections page (kept out of the
feed and sitemap by the compiler, stamped `draft` on the page). Copy each
block to the named path under a scratch content directory. This
checkout-only command extracts them without adding a product build stage:

````bash
mkdir -p test-output/columns-specimen/content/harbour
awk -v root=test-output/columns-specimen/content '
  /^### .*\.md$/ { path = $2 }
  !writing && path != "" && ($0 == "```markdown" || $0 == "````markdown") {
    fence = substr($0, 1, length($0) - 8); file = root "/" path; writing = 1; next
  }
  writing && $0 == fence { close(file); writing = 0; path = ""; next }
  writing { print > file }
' themes/columns/README.md
````

Then compile it:

```bash
./zig-out/bin/boris \
  --input test-output/columns-specimen/content \
  --theme themes/columns \
  --layout-rule default id:index themes/columns/layouts/home.html \
  --layout-rule default id:harbour themes/columns/layouts/section.html \
  --html-dir test-output/columns-specimen/dist \
  --quiet
```

For an arbitrary tree the usual recipe is `id:index` → `home.html` plus
`role:trunk` → `section.html` (the exact-id rule wins on the index).

### index.md

```markdown
---
title: The Tidewater Courier
status: published
tags: [frontpage, edition]
---
# Dredge holds the channel; ferry misses the tide

TIDEWATER — The harbour dredge *Oystercatcher* held the main channel
through a second week of tides, while the morning ferry missed its
sailing twice on the ebb. Both stories file under the Harbour desk.

The desks are listed above the fold; the edition index runs below it.
```

### harbour.md

```markdown
---
title: Harbour desk
status: published
parent: index
tags: [desk, harbour]
---
# Harbour desk

Shipping, weather, and anything that floats or fails to. The desk files
before the evening tide and corrects in the morning edition.
```

### harbour/dredging.md

```markdown
---
title: Dredge works the channel a second week
status: published
parent: harbour
tags: [harbour, shipping]
relations: [relates_to=harbour/ferry]
---
# Dredge works the channel a second week

TIDEWATER — The dredge *Oystercatcher* entered its second week on the
main channel Monday, pilots reporting six feet of clearance at low water
while the bar still bites on the ebb. The harbourmaster expects the cut
to hold through Friday if the weather stays off the southwest.

Channel traffic moved without incident through the morning tide. Two
coasters held at the anchorage overnight rather than transit the bar in
the dark, which the pilots' office called prudent and the harbour board
called expensive.

## At the bar

Soundings taken at first light showed the inner bar a foot shallower
than the chart. The dredge shifted to the inner reach at slack water and
will work it until Thursday.

| Reach | Charted depth | Sounded |
|---|---|---|
| Inner bar | 4.2 m | 3.9 m |
| Main channel | 6.5 m | 6.0 m |
| Outer approach | 7.8 m | 7.8 m |

<Aside kind="note">
The harbourmaster's office posts revised soundings at the pilot station
every morning the dredge is working.
</Aside>
```

### harbour/ferry.md

```markdown
---
title: Ferry misses the morning tide again
status: published
parent: harbour
tags: [harbour, ferry]
---
# Ferry misses the morning tide again

TIDEWATER — The morning ferry stood off the slip for the second time in
a week Tuesday, held by the same ebb that keeps the dredge honest. The
crossing ran forty minutes late and the queue ran the length of the
fish dock.

The operator lays the delay on the shoaling bar. Regulars lay it on the
ferry. Both can be true; both usually are.
```

### tides.md

```markdown
---
title: Tide tables
status: published
parent: index
tags: [standing]
---
# Tide tables

Highs and lows for the week, as posted at the pilot station.

| Day | High | Low |
|---|---|---|
| Monday | 06:12 | 12:40 |
| Tuesday | 07:01 | 13:28 |
| Wednesday | 07:52 | 14:16 |
| Thursday | 08:44 | 15:05 |
| Friday | 09:38 | 15:57 |
```

### corrections.md

```markdown
---
title: Corrections and clarifications
status: draft
parent: index
tags: [press-room]
relations: [depends_on=harbour/dredging]
---
# Corrections and clarifications

Holding for the morning edition: Monday's harbour report put the
*Oystercatcher* off the wrong buoy. The dredge was working the inner
bar, not the outer. The desk regrets the error.
```

## Slot coverage

All three layouts carry `{{relations}}` and `{{backlinks}}`, labelled
"Related stories" and "Picked up by" in the wire block, with the relation
kind printed as a small tag. Both emit nothing on a page without semantic
relations, and empty blocks hide themselves.

Intentionally absent:

- `{{tags}}` — `{{metadata}}` already prints Tags in the credit line. A
  second per-tag list would repeat it.
- `{{parent}}` — `{{breadcrumb}}` already links the parent in the press
  line; the front page has no parent.
