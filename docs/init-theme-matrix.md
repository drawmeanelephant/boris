# `boris init --type` theme coverage matrix

Which first-party themes fit each `boris init --type` scenario. This is the
source of truth the per-archetype issues cite
([#1051](https://github.com/drawmeanelephant/boris/issues/1051), epic
[#1046](https://github.com/drawmeanelephant/boris/issues/1046)). It also
answers "which theme should I try?" for an existing tree.

Every scenario names at least two catalog themes from
[`themes/`](../themes/README.md). When a fitting second theme does not
exist, the row records a gap note instead. The **Starter** column is the
theme `init` embeds for that archetype. The other columns are alternates
you select with `--theme themes/NAME`, or by editing the starter profile's
`theme` and `layout_rules` paths. The shipped `--type` names and their
behavior are normative in
[the CLI contract](contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification).

## Matrix

| Scenario | `--type` | Teaches | Starter theme | Alternates (verified) | Gap note |
|---|---|---|---|---|---|
| docs | `docs` | trunk/satellite graph, wiki links, a relation, search client | `boris` | `reference`, `engineering` (home), `semantic` | — (resolved by [#1063](https://github.com/drawmeanelephant/boris/issues/1063): the starter embeds the catalog `boris` theme, so its relation renders on both ends. `boris` hardcodes its brand line. See [Theme gaps](#theme-gaps).) |
| garden | `garden` | dense wiki links, relations, `{{include}}`, `<Aside>` | `ledger` | `field-notes`, `archive` | — |
| cookbook | `cookbook` | Cooklang `.cook` pages, `servings`, `{{children}}` recipe deck | `cards` (home) | `reading`, `cozy` | Thin second option: no other card-shaped recipe theme. Both alternates build but are generic reading shells. |
| blog | `blog` | `published_at` posts on a parent chain | `cozy` | `journal`, `showcase` | — |
| textile | `textile` | `input_format: textile` | `press` | `reading` | — |
| portfolio | `portfolio` ([#1053](https://github.com/drawmeanelephant/boris/issues/1053)) | `layout_rules` named layouts, `{{children}}` | `showcase` (home) | `minimal` | — (resolved: `showcase/layouts/home.html` renders `{{children}}`, so the index lists the work with no hand-kept list) |
| landing | `landing` ([#1054](https://github.com/drawmeanelephant/boris/issues/1054)) | single-Trunk graph, `{{include}}` sections, `layout_rules` | `service` (home) | `civic` (home), `corporate` | No marketing-hero theme exists. `service`'s public-information home is the honest fit. |
| wiki | `wiki` ([#1055](https://github.com/drawmeanelephant/boris/issues/1055)) | deep parent chains, `{{toc}}`, `{{breadcrumb}}` | `reference` (home + section) | `engineering` (home), `semantic` (home) | — |
| changelog | `changelog` ([#1056](https://github.com/drawmeanelephant/boris/issues/1056)) | `published_at` entries, `status: draft`, `{{children}}` hub listing | `journal` (archive on `changes`) | `compact`, `press` | — |
| link-in-bio | `link-in-bio` ([#1057](https://github.com/drawmeanelephant/boris/issues/1057)) | a one-page site | `minimal` | `cards` | — |
| resume | `resume` ([#1058](https://github.com/drawmeanelephant/boris/issues/1058)) | `{{metadata}}` / tags, print stylesheet | `corporate` | `compact`, `minimal` | — (resolved: print hides the page furniture the CV used to carry. See [Theme gaps](#theme-gaps).) |
| archive | `archive` ([#1059](https://github.com/drawmeanelephant/boris/issues/1059)) | `tags` + `relations` taxonomy, `{{backlinks}}`, `status: archived` | `archive` (archive) | `ledger`, `field-notes` | `archive` hardcodes its masthead copy. See [Theme gaps](#theme-gaps). |
| newsletter | `newsletter` ([#1060](https://github.com/drawmeanelephant/boris/issues/1060)) | `published_at` issues, profile `rss` / `sitemap` | `press` (home, archive, blog) | `journal`, `cozy` | — (resolved: press layouts carry `{{head}}`, so the starter's profile ships `rss` on an enabled `head`) |
| photo-gallery | `photo-gallery` ([#1061](https://github.com/drawmeanelephant/boris/issues/1061)) | `{stem}.assets/` content-local images, `<figure>` captions | `gallery` (home) | `showcase` (partial), `cards` (partial) | Both alternates publish every image but do not style `gallery-grid`, so figures stack in one column. |
| dashboard | `dashboard` ([#1062](https://github.com/drawmeanelephant/boris/issues/1062)) | `status:` as visible page state, dense tables, relations | `engineering` (home) | `ledger`, `corporate` (partial) | `corporate` shows status only as plain `{{metadata}}` text; it has no `{{page-status}}` hook. |

"(home)" means the pairing was also built with
`--layout-rule default id:index themes/NAME/layouts/home.html`.
"(archive)" is the same rule pointing at `layouts/archive.html`, and
"(archive on `changes`)" sends `id:changes` there instead. `wiki`'s
"(home + section)" adds `glob:wiki/*` → `layouts/section.html`. The
starter's own `layout_rules` are listed in
[the CLI contract](contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification).

Two starters use named layouts added by
[#1050](https://github.com/drawmeanelephant/boris/issues/1050):
`cookbook` sends its index to `cards/layouts/home.html`, a numbered, tabbed
index-card workbench with one card per recipe (the full graph folds into an
index drawer, not a sidebar), and `changelog` sends its `changes` hub to
`journal/layouts/archive.html`, a log listing of the published releases.

## How the pairings were verified

Every pairing above was smoke-built again on 2026-10-10 on the wave-3
integration line plus the wave-4 init branch, at `516840d5`. Each
scenario used the tree that `boris init --type NAME` writes. The build
command was
`boris --input content --html-dir dist --theme themes/NAME`, plus
`--cooklang` or `--textile` for those scenarios and the layout rules
where marked.

All 43 builds exited 0. Each wrote a stylesheet and every page, and all
three `photo-gallery` themes published the five images. Every starter is
also covered by `zig build test-boris-init` through its own profile.

The `docs` row was verified again for
[#1063](https://github.com/drawmeanelephant/boris/issues/1063), on the
wave-5 docs-starter branch. The starter now writes the catalog `boris`
theme. Its three pages built under `boris`, `reference`, `engineering`
(also with the home rule), and `semantic`. Each build rendered the
`relates_to` edge twice: as `{{relations}}` on `guides/publishing` and as
`{{backlinks}}` on `guides/getting-started`.

The `docs` alternates were also built through the docs starter's
publication profile with the theme swapped in. `reference`, `engineering`,
and `semantic` all pass the `rendered-search` check now, because each
marks its search extraction root. Only the `boris` theme ships the
browser search client, so the alternates publish a correct search index
with no search box on the page.

The Cards index-card redesign was re-verified on 2026-10-10 against the
`cookbook` starter (home rule), `link-in-bio` (main), and `photo-gallery`
(main) using the redesigned catalog theme. All three built with intact local
links and assets; the gallery remains a stacked-image partial fit. Cards now
uses a native index drawer and folded page outline instead of navigation rails.

The Field Notes expedition-logbook redesign was re-verified on 2026-10-11
against the `garden` and `archive` starters (both `main`, the layouts each
row names) using the redesigned theme. Both built complete trees with intact
links and assets. Field Notes now renders pages as grid-paper leaves behind
a punched binding, with the graph in a logbook-index margin column instead
of navigation rails.

Re-verify a row after a theme changes by rebuilding the scenario tree with
the named theme. A starter archetype is also re-verified by `zig build
test-boris-init`.

## Theme slot coverage

The teaching slots per starter theme at `516840d5`, after the slot
adoption passes
([#1047](https://github.com/drawmeanelephant/boris/issues/1047),
[#1048](https://github.com/drawmeanelephant/boris/issues/1048)), the new
`gallery` theme ([#1052](https://github.com/drawmeanelephant/boris/issues/1052)),
and the named layouts
([#1050](https://github.com/drawmeanelephant/boris/issues/1050): `cards`
`home`, `journal` `archive`, and the showcase home `{{children}}` grid).
Each cell lists the layouts that carry the slot; `-` means none:

| Theme | `{{children}}` | `{{toc}}` | `{{breadcrumb}}` | `{{relations}}` | `{{backlinks}}` | `{{head}}` | `{{page-status}}` |
|---|---|---|---|---|---|---|---|
| `archive` | archive, main | archive, main | archive, main | archive, main | archive, main | archive, main | archive, main |
| `boris` | main | main | main | main | main | main | - |
| `cards` | home, main | home, main | home, main | home, main | home, main | home, main | home, main |
| `corporate` | main | main | main | main | main | main | - |
| `cozy` | main | main | main | main | main | main | main |
| `engineering` | home, main, section | home, main, section | main, section | home, main, section | home, main, section | home, main, section | home, main, section |
| `gallery` | home, main | - | main | home, main | home, main | home, main | home, main |
| `journal` | archive, main | archive, main | archive, main | archive, main | archive, main | archive, main | archive, main |
| `ledger` | main | main | main | main | main | main | main |
| `minimal` | main | main | main | main | main | main | - |
| `press` | all five | all five | archive, blog, main, section | all five | all five | all five | all five |
| `reference` | section | main | main, section | home, main, section | home, main, section | home, main, section | - |
| `service` | home, main, section | home, main, section | main, section | home, main, section | home, main, section | home, main, section | home, main, section |
| `showcase` | all four | all four | blog, main, section | all four | all four | all four | all four |

## Theme gaps

Gaps that keep a starter's teaching point from fully rendering.
Each starter still compiles and says what it does. These belong to the
theme slot work ([#1047](https://github.com/drawmeanelephant/boris/issues/1047)
and [#1048](https://github.com/drawmeanelephant/boris/issues/1048)), not to
`init`.

- ~~**`press` has no `{{head}}`.**~~ Resolved: all five press layouts now
  carry `{{head}}`, so the `newsletter` starter's profile enables `head`
  and declares `rss`
  ([head metadata](contracts/head-metadata.md#bounded-rss-rider-and-execution-boundary)).
  Its first build writes a three-item `dist/feed.xml` and an autodiscovery
  link in every non-draft head.
- ~~**`showcase/layouts/home.html` has no `{{children}}`.**~~ Resolved:
  the showcase home renders `{{children}}` as its project grid, so the
  `portfolio` index keeps only a short intro, and the about page and the
  three projects are listed by the layout.
- ~~**`corporate` print leaves page furniture in the CV.**~~ Resolved by
  the corporate print pass
  ([#1048](https://github.com/drawmeanelephant/boris/issues/1048),
  [#1050](https://github.com/drawmeanelephant/boris/issues/1050)). In print,
  `@media print` now also hides the breadcrumb, the page metadata, the
  `{{children}}` list, the relation blocks, and the theme footer. It sets a
  white surface, underlines body links, and prints each external URL after
  its link. This was checked against the stylesheet and the class names in
  the built `resume` page. It was not printed to PDF again.
- ~~**`reference`, `showcase`, and `press` have no `{{relations}}` /
  `{{backlinks}}`.**~~ Resolved: all three now carry both slots, and the
  `wiki`, `portfolio`, and `newsletter` starters' typed edges render on
  both ends.
- **`archive` hardcodes its masthead copy.** `archive.html` prints a fixed
  `<title>` ("Field Notes Archive"), a fixed eyebrow ("Personal index ·
  2018—2024"), and a fixed lede ("Small records, held in order."), and
  `main.html` repeats the eyebrow. The `archive` starter's own title shows
  only in the `<h1>`, so a fresh starter carries another site's dates.
- **`boris` hardcodes its brand line.** `main.html` prints the `<title>`
  suffix "· Boris", the sidebar name "Boris", and a compiler tagline.
  `footer.html` repeats the product name. The `docs` starter's
  `site.title` ("My Boris Site") does not reach that chrome. The private
  starter theme that #1063 retired hardcoded "My Boris Site" there
  instead. The starter's conventions report says to edit the copy.
- **`engineering` hardcodes its chrome.** Every layout's `<title>` is the
  static word "Engineering" (a known limitation in the theme README), and
  `home.html` labels the index "Theme study". The `dashboard` board shows
  that label above its own title.
- **Theme READMEs link to `../../examples/…`.** Every starter copies its
  theme README byte for byte. That README links to the repository's
  sample site, and the link is dead in a fresh starter tree. The sibling
  links (`ACCESSIBILITY.md`, `MIGRATION.md`) resolve, because every starter
  now writes its theme's full file set.
