# Examples

Sample sites and unfinished theme studies. Shipped first-class themes live
under [`themes/`](../themes/). This folder is not retired; it is no longer a
second theme attic.

## Sample sites (consume a shipped theme)

| Site | Theme | What it shows |
|---|---|---|
| [`reference-site`](reference-site/) | [`themes/reference`](../themes/reference/) | Docs graph, Aside, Details, page-local assets, layout rules |
| [`press-site`](press-site/) | [`themes/press`](../themes/press/) | Editorial docs + blog + archive |
| [`showcase-site`](showcase-site/) | [`themes/showcase`](../themes/showcase/) | Docs + blog with a soft component shell |
| [`archive-site`](archive-site/) | [`themes/archive`](../themes/archive/) | Ordered field-note archive |
| [`field-notes-site`](field-notes-site/) | [`themes/field-notes`](../themes/field-notes/) | Compact docs graph |
| [`compact-site`](compact-site/) | [`themes/compact`](../themes/compact/) | Small-type docs |
| [`cards-site`](cards-site/) | [`themes/cards`](../themes/cards/) | Soft cards; `home.html` child-card deck |
| [`cozy-site`](cozy-site/) | [`themes/cozy`](../themes/cozy/) | Personal blog |
| [`journal-site`](journal-site/) | [`themes/journal`](../themes/journal/) | Terminal diary; `archive.html` log index |
| [`ledger-site`](ledger-site/) | [`themes/ledger`](../themes/ledger/) | Dense node pages |
| [`reading-site`](reading-site/) | [`themes/reading`](../themes/reading/) | `:lang` typesetting specimens |
| [`lab-site`](lab-site/) | [`themes/lab`](../themes/lab/) | Three color modes, graph panel, dropdown search |
| [`gallery-site`](gallery-site/) | [`themes/gallery`](../themes/gallery/) | Album grid, figures/captions, page-local `{stem}.assets/` images at three depths |
| [`studies-site`](studies-site/) | `semantic` / `columns` / `service` / `engineering` / `civic` / `tokens` / `corporate` / `minimal`, plus `boris` and `html4-strict` | One docs corpus; swap `--theme` |

Each site README has the exact `boris` invocation, including every
`--layout-rule` for named layouts. Keep generated trees under ignored
`test-output/` or `.zig-cache/`.

## Specimen for every theme

Every catalog theme in [`themes/`](../themes/README.md) builds a specimen
with exit 0. A theme without its own `*-site` shares `studies-site`. Those
themes all style the same docs shape, so one corpus keeps them comparable,
and the corpus covers Aside, Details, tables, a footnote, page-local images,
and a typed relation. See [`studies-site/README.md`](studies-site/README.md)
for the per-theme commands.

| Theme | Specimen |
|---|---|
| `archive`, `cards`, `compact`, `cozy`, `field-notes`, `gallery`, `journal`, `lab`, `ledger`, `press`, `reading`, `reference`, `showcase` | Own `examples/<theme>-site/` |
| `semantic`, `columns`, `service`, `engineering`, `civic`, `tokens` | `studies-site` with the theme's `home.html` / `section.html` rules |
| `blueprint` | `studies-site` with the `id:index` → `home.html` rule. The `boris init --type blueprint` tree is its teaching specimen |
| `corporate`, `minimal` | `studies-site` with no layout rules. The `boris init --type resume` tree is corporate's print specimen |
| `boris` | `studies-site` with no layout rules. The repository's own [`content/`](../content/) docs site is its dogfood specimen |
| `html4-strict` | `studies-site` under `--target-profile default=html4-strict`. [`fixtures/html4-strict/content`](../fixtures/html4-strict/content/) is the minimal regression fixture |

The shipped themes do not vendor other projects. If a future theme ships
upstream CSS, it must record version, license, and the URL of the current
release next to the file.

## Shared checks

After building a sample site:

```bash
rg -n 'https?://|<script src=|@import' test-output/<name> --glob '*.html' --glob '*.css' || true
```

That command should print nothing. The one exception is an `html4-strict`
build: every page prints its DOCTYPE line, because the Strict DOCTYPE names
the `http://www.w3.org/TR/html4/strict.dtd` system identifier. That is an
identifier the profile requires, not a fetched resource. Report compiler
defects as Boris issues;
do not repair the engine from an example.

## Host examples (not sites)

| Path | What it is |
|---|---|
| [`cloudflare-container`](cloudflare-container/) | Worker + Container host for `boris-job-runner` ([#300](https://github.com/drawmeanelephant/boris/issues/300)). Not a publication target. |

## Related

- Theme bar and catalog: [`themes/README.md`](../themes/README.md)
- Contract: [`docs/contracts/templating-and-themes.md`](../docs/contracts/templating-and-themes.md)
- Issue: [#574](https://github.com/drawmeanelephant/boris/issues/574)
