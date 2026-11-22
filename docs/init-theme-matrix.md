# `boris init --type` theme coverage matrix

Which first-party themes fit each `boris init --type` starter archetype.
It also answers "which theme should I try?" for an existing tree.

Every starter names at least two catalog themes from
[`themes/`](../themes/README.md). The **Starter** column is the theme `init`
embeds for that archetype. The other columns are alternates you select with
`--theme themes/NAME`, or by editing the starter profile's `theme` and
`layout_rules` paths. All 24 themes remain first-class under
[`themes/`](../themes/README.md) with specimens under
[`examples/`](../examples/README.md); `boris init --type` is scoped to the
six core shapes that exercise distinct compiler modes and seams. The shipped
`--type` names and their behavior are normative in
[the CLI contract](contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification).

## Matrix

| Scenario | `--type` | Teaches | Starter theme | Alternates (verified) | Gap note |
|---|---|---|---|---|---|
| docs | `docs` | trunk/satellite graph, wiki links, a relation, search client | `boris` | `blueprint`, `reference`, `engineering` (home), `semantic` | `boris` hardcodes its brand line. See [Theme gaps](#theme-gaps). |
| garden | `garden` | dense wiki links, relations, `{{include}}`, `<Aside>` | `ledger` | `field-notes`, `archive` | — |
| cookbook | `cookbook` | Cooklang `.cook` pages, `servings`, `{{children}}` recipe deck | `cards` (home) | `reading`, `cozy` | Thin second option: no other card-shaped recipe theme. Both alternates build but are generic reading shells. |
| blog | `blog` | `published_at` posts on a parent chain, `status: draft` gating, profile `head` + `rss` + `sitemap` | `cozy` | `press`, `journal`, `showcase` | — |
| textile | `textile` | `input_format: textile` | `press` | `reading` | — |
| photo-gallery | `photo-gallery` | `{stem}.assets/` content-local images, `<figure>` captions | `gallery` (home) | `showcase` (partial), `cards` (partial) | Both alternates publish every image but do not style `gallery-grid`, so figures stack in one column. |

"(home)" means the pairing was also built with
`--layout-rule default id:index themes/NAME/layouts/home.html`. Each
starter's own `layout_rules` are listed in
[the CLI contract](contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification).

## Verification

Every starter archetype is verified by `zig build test-boris-init` through
its own `boris.json` profile, including byte-identical theme copies against
`themes/`, deterministic re-runs, and refusal on non-empty targets.
Re-verify a row after a theme changes by rebuilding the scenario tree with
the named theme.

## Theme slot coverage

The current teaching slots per starter theme. Each cell lists the layouts
that carry the slot; `-` means none:

| Theme | `{{children}}` | `{{toc}}` | `{{breadcrumb}}` | `{{relations}}` | `{{backlinks}}` | `{{head}}` | `{{page-status}}` |
|---|---|---|---|---|---|---|---|
| `boris` | main | main | main | main | main | main | - |
| `cards` | home, main | home, main | home, main | home, main | home, main | home, main | home, main |
| `cozy` | main | main | main | main | main | main | main |
| `gallery` | home, main | - | main | home, main | home, main | home, main | home, main |
| `ledger` | main | main | main | main | main | main | main |
| `press` | all five | all five | archive, blog, main, section | all five | all five | all five | all five |

## Theme gaps

Known polish gaps in starter themes that belong to theme work rather than
`init`:

- **`boris` hardcodes its brand line.** `main.html` prints the `<title>`
  suffix "· Boris", the sidebar name "Boris", and a compiler tagline.
  `footer.html` repeats the product name. The `docs` starter's
  `site.title` ("My Boris Site") does not reach that chrome; the starter's
  conventions report says to edit the copy.
- **Theme READMEs link to `../../examples/…`.** Every starter copies its
  theme README byte for byte. Links to the repository's sample site do not
  resolve inside a fresh standalone starter tree; sibling links
  (`ACCESSIBILITY.md`, `MIGRATION.md`) do resolve because every starter
  writes its theme's full file set.
