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
| docs | `docs` | trunk/satellite graph, wiki links, search client | `boris` (embedded starter copy) | `reference`, `engineering` (home), `semantic` | Starter-theme decision pending ([#1063](https://github.com/drawmeanelephant/boris/issues/1063)); this matrix does not decide it. |
| garden | `garden` | dense wiki links, relations, `{{include}}`, `<Aside>` | `ledger` | `field-notes`, `archive` | `field-notes` and `archive` do not render `{{relations}}` / `{{backlinks}}`. |
| cookbook | `cookbook` | Cooklang `.cook` pages, `servings` | `cards` | `reading`, `cozy` | Thin second option: no other card-shaped recipe theme. Both alternates build but are generic reading shells. |
| blog | `blog` | `published_at` posts on a parent chain | `cozy` | `journal`, `showcase` | — |
| textile | `textile` | `input_format: textile` | `press` | `reading` | — |
| portfolio | `portfolio` ([#1053](https://github.com/drawmeanelephant/boris/issues/1053)) | `layout_rules` named layouts, `{{children}}` | `showcase` (home) | `minimal` | `showcase/layouts/home.html` has no `{{children}}` slot, so the home page does not list the work automatically yet. |
| landing | `landing` ([#1054](https://github.com/drawmeanelephant/boris/issues/1054)) | single-Trunk graph, `{{include}}` sections, `layout_rules` | `service` (home) | `civic` (home), `corporate` | No marketing-hero theme exists. `service`'s public-information home is the honest fit. |
| wiki | `wiki` ([#1055](https://github.com/drawmeanelephant/boris/issues/1055)) | deep parent chains, `{{toc}}`, `{{breadcrumb}}` | `reference` (home + section) | `engineering` (home), `semantic` (home) | `reference` has no `{{relations}}` / `{{backlinks}}`, so the starter's typed edge validates but does not render. |
| changelog | `changelog` ([#1056](https://github.com/drawmeanelephant/boris/issues/1056)) | `published_at` entries, `status: draft` | `journal` | `compact`, `press` | — |
| link-in-bio | `link-in-bio` ([#1057](https://github.com/drawmeanelephant/boris/issues/1057)) | a one-page site | `minimal` | `cards` | — |
| resume | `resume` ([#1058](https://github.com/drawmeanelephant/boris/issues/1058)) | `{{metadata}}` / tags, print stylesheet | `corporate` | `compact`, `minimal` | Print yields a clean single column, with leftovers. See [Theme gaps](#theme-gaps) and [#1048](https://github.com/drawmeanelephant/boris/issues/1048). |
| archive | later ([#1059](https://github.com/drawmeanelephant/boris/issues/1059)) | `tags` + `relations` taxonomy, `{{backlinks}}` | `archive` | `ledger`, `field-notes` | Slot adoption on `archive` (`{{relations}}`, `{{backlinks}}`) is pending in [#1047](https://github.com/drawmeanelephant/boris/issues/1047). |
| newsletter | `newsletter` ([#1060](https://github.com/drawmeanelephant/boris/issues/1060)) | `published_at` issues, profile `rss` / `sitemap` | `press` (home, archive, blog) | `journal`, `cozy` | — (resolved: press layouts carry `{{head}}`, so the starter's profile ships `rss` on an enabled `head`) |
| photo-gallery | later ([#1061](https://github.com/drawmeanelephant/boris/issues/1061)) | `{stem}.assets/` content-local images | `gallery` (new) | `showcase` (partial), `cards` | No image-first theme yet. The `gallery` theme is [#1052](https://github.com/drawmeanelephant/boris/issues/1052) and in progress. |
| dashboard | later ([#1062](https://github.com/drawmeanelephant/boris/issues/1062)) | `status:` field, dense tables / relations | `engineering` | `ledger`, `corporate` | The `{{page-status}}` slot adoption on `engineering` is pending in [#1047](https://github.com/drawmeanelephant/boris/issues/1047). |

"(home)" means the pairing was also built with
`--layout-rule default id:index themes/NAME/layouts/home.html`.

## How the pairings were verified

Each pairing above was smoke-built on 2026-10-10 against `main` at
`3710547d` using `boris --input content --html-dir dist --theme themes/NAME`
(plus `--cooklang` / `--textile` for those scenarios, and the home rule
where marked). The content was the scenario's representative tree:

- The shipped archetypes (`docs`, `garden`, `cookbook`, `blog`, `textile`)
  used the tree `boris init --type NAME` writes.
- The wave-1 archetypes used the content their starters ship.
- `archive` used `examples/archive-site/content`.
- `photo-gallery` and `dashboard` used a two- or three-page specimen: a
  page with two `{stem}.assets/` SVG images, and `status:` pages with
  Markdown tables and a `depends_on` relation.

All 42 builds exited 0 and wrote a stylesheet and every page. Two `docs`
builds (`engineering`, `semantic`) report the `rendered-search` publication
check as failed. Those themes do not mark the search extraction root that
the docs starter's search client expects, so search works only under the
starter theme.

Re-verify a row after a theme changes by rebuilding the scenario tree with
the named theme. A starter archetype is also re-verified by `zig build
test-boris-init`.

## Theme slot coverage

The teaching slots per theme on `main` at `3710547d` (layouts that carry
the slot; `-` means none):

| Theme | `{{children}}` | `{{toc}}` | `{{breadcrumb}}` | `{{relations}}` | `{{backlinks}}` | `{{head}}` |
|---|---|---|---|---|---|---|
| `archive` | archive, main | archive, main | archive, main | - | - | - |
| `cards` | main | main | main | - | - | main |
| `corporate` | main | main | main | main | main | main |
| `cozy` | main | main | main | - | - | main |
| `journal` | main | main | main | - | - | main |
| `ledger` | main | main | main | main | main | main |
| `minimal` | main | main | main | main | main | main |
| `press` | all five | all five | archive, blog, main, section | - | - | - |
| `reference` | section | main | main, section | - | - | - |
| `service` | home, main, section | home, main, section | main, section | home, main, section | home, main, section | home, main, section |
| `showcase` | blog, main, section | all four | blog, main, section | - | - | - |

## Theme gaps

Gaps that keep a wave-1 starter's teaching point from fully rendering.
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
- **`showcase/layouts/home.html` has no `{{children}}`.** The `portfolio`
  index lists its projects with hand-written wiki links until the slot
  lands.
- **`corporate` print leaves page furniture in the CV.** The `resume`
  starter was printed to PDF with headless Chrome (`--print-to-pdf`, two
  Letter pages). Its `@media print` hides the header, sidebar, contents
  rail, and search, and drops the flex layout, so the CV body prints as one
  clean column. The following still print:
  - the breadcrumb, as a numbered list ("1. Ada Brennan");
  - the `{{children}}` list (a bare "• Now");
  - the theme footer ("Corporate · themes/corporate");
  - the light surface background.

  Links have no underline or URL in print, so a printed wiki link is
  indistinguishable from prose. These belong to the corporate print pass
  ([#1048](https://github.com/drawmeanelephant/boris/issues/1048)).
- **`reference`, `showcase`, and `press` have no `{{relations}}` /
  `{{backlinks}}`.** The `wiki`, `portfolio`, and `newsletter` starters'
  typed edges validate but do not render.
