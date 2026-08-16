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
| [`cards-site`](cards-site/) | [`themes/cards`](../themes/cards/) | Soft cards |
| [`cozy-site`](cozy-site/) | [`themes/cozy`](../themes/cozy/) | Personal blog |
| [`journal-site`](journal-site/) | [`themes/journal`](../themes/journal/) | Terminal diary |
| [`ledger-site`](ledger-site/) | [`themes/ledger`](../themes/ledger/) | Dense node pages |
| [`reading-site`](reading-site/) | [`themes/reading`](../themes/reading/) | `:lang` typesetting specimens |
| [`studies-site`](studies-site/) | `semantic` / `columns` / `service` / `engineering` / `civic` / `tokens` | One corpus; swap `--theme` |

Each site README has the exact `boris` invocation. Keep generated trees under
ignored `test-output/` or `.zig-cache/`.

## Not yet first-class

These trees stay here. They do not meet [`themes/README.md`](../themes/README.md).

| Tree | Why it stays |
|---|---|
| `prototype-corporate` / `prototype-minimalist` | Visual research. Dead buttons and `#` nav. |

The framework studies do not vendor those projects. If a future theme ships
upstream CSS, it must record version, license, and the URL of the current
release next to the file.

## Shared checks

After building a sample site:

```bash
rg -n 'https?://|<script src=|@import' test-output/<name> --glob '*.html' --glob '*.css' || true
```

That command should print nothing. Report compiler defects as Boris issues;
do not repair the engine from an example.

## Related

- Theme bar and catalog: [`themes/README.md`](../themes/README.md)
- Contract: [`docs/contracts/templating-and-themes.md`](../docs/contracts/templating-and-themes.md)
- Issue: [#574](https://github.com/drawmeanelephant/boris/issues/574)
