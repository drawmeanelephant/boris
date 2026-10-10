# Minimal

The same three-column shell as Corporate, without search, and flatter:
square corners, no tints, cards, or shadows. Asides are a coloured rule on
one flat panel; tables, children, and relations are ruled lists.
Navigation is the no-JavaScript path. See [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `main.html`
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

Single shape by design. Minimal is Corporate's shell without search. It
stays one layout so the pair stays comparable on the shared specimen. The
starter that uses it, `link-in-bio`, is a one-page site and has no second
page to shape. As the `portfolio` alternate it renders the project list
through `main.html`'s `{{children}}`.

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Directly inside `<head>` (already present). |
| `{{relations}}` / `{{backlinks}}` | After the children list (already present), now labelled "Related" / "Backlinks" with a kind column, inside a `data-boris-search-exclude` wrapper. Pages with no relations emit nothing. |
| `{{tags}}` | Intentionally absent. The metadata line lists tags; this theme's point is to add nothing beyond it. |
| `{{parent}}` | Intentionally absent. `{{breadcrumb}}` opens the content column and already links the parent. |
| `{{page-status}}` | Intentionally absent. The metadata line states the status in text; there is no badge chrome to carry it. |

## Search

Intentionally absent: Minimal is Corporate's shell without the search UI.
`main` still carries `data-boris-search-root` and the outline rail and
relations wrapper carry `data-boris-search-exclude`, so the rendered search
index Boris emits stays limited to page prose.
