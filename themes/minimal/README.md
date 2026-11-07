# Minimal

The same three-column shell as Corporate, without search, and flatter:
square corners, no tints, cards, or shadows. Asides are a coloured rule on
one flat panel; tables, children, and relations are ruled lists.
Navigation is the no-JavaScript path. See [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `main.html`, `links.html`
- Specimen: [`examples/studies-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/studies-site/)

Build the specimen from a Boris checkout:

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/minimal \
  --html-dir test-output/minimal \
  --quiet
```

## Named layouts

`main.html` remains Corporate's comparable documentation shell without search.
`links.html` is the focused one-page front selected by `boris init --type
link-in-bio`: the authored identity and link rows lead, with no redundant
menu, breadcrumb, metadata line or outline rail.

Select it for an index with
`--layout-rule default id:index themes/minimal/layouts/links.html`. The
starter's profile already declares that rule. Other pages still use `main`.
As a `portfolio` alternate, `main` continues to list work through `{{children}}`.
Use top-level Markdown lists for link rows (one link per item, tight or loose);
contextual inline links belong in paragraphs outside those lists.
The extra local `assets/links.css` is loaded only by the focused layout.

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Directly inside `<head>` (already present). |
| `{{relations}}` / `{{backlinks}}` | After the children list (already present), now labelled "Related" / "Backlinks" with a kind column, inside a `data-boris-search-exclude` wrapper. Pages with no relations emit nothing. |
| `{{tags}}` | Intentionally absent. `main` lists tags in metadata; `links` omits metadata chrome. |
| `{{parent}}` | Intentionally absent. `main` already links the parent through `{{breadcrumb}}`; the focused link front omits it. |
| `{{page-status}}` | Intentionally absent. `main` states status in its metadata line; `links` has no metadata or badge chrome. |

## Search

Intentionally absent: Minimal is Corporate's shell without the search UI.
Both layouts carry `data-boris-search-root`. Graph chrome, and `main`'s
outline rail, carry `data-boris-search-exclude`, so the rendered search
index Boris emits stays limited to page prose.
