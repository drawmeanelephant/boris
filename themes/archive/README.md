# Archive

Ordered long-lived field notes. Direct children are the index; entry pages
use the fallback layout. See [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `archive.html` (`id:archive`), `main.html`
- Assets: `assets/archive.css`. System Palatino/Georgia serif.
- Sample site: [`examples/archive-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/archive-site/)

Build the specimen from a Boris checkout:

```bash
./zig-out/bin/boris \
  --input examples/archive-site/content \
  --theme themes/archive \
  --layout-rule default id:archive themes/archive/layouts/archive.html \
  --html-dir test-output/archive \
  --quiet
```

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Both layouts, directly inside `<head>`. |
| `{{relations}}` / `{{backlinks}}` | Both layouts, after the note, as an index-card "Cross-references" / "Referenced in" table with the kind in the left column. The wrapper is `data-boris-search-exclude`. Pages with no relations emit nothing. |
| `{{tags}}` | Both layouts, as a monospace `#tag` line under the metadata strip; the duplicate Tags entry in the strip is hidden. An archive is browsed by tag, so the list earns its place. |
| `{{page-status}}` | Both layouts, as `<body data-status="…">`. Draft entries outline the Status entry in the accent colour; archived entries print it reversed (paper on ink) like a sealed record. |
| `{{parent}}` | `main.html` only, as a "↩ Filed in …" return link after the note, so a reader who finishes an entry lands back on its index. Omitted from `archive.html`, which serves the `archive` index itself. |

## Search

No search UI ships. Each `main` carries `data-boris-search-root`. The index
masthead, section label, children list, and relations wrapper carry
`data-boris-search-exclude`, so the rendered search index stays limited to
note prose. The masthead `<h1>` also carries
`data-boris-search-title="layout"`, so the index document's search title is
the page title even though the heading itself is excluded.

The index section and the "More entries" panel hide when the page has no
children, and a sidebar module hides when its slot is empty.

## Known limitation: browser-tab title

`archive.html` spends its one `{{title}}` slot on the masthead `<h1>`, so
the index's document `<title>` is the static word "Archive". A slot may
appear at most once per layout
([`templating-and-themes.md`](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/templating-and-themes.md)
§3). `main.html` has no visible title heading, so its `<title>` carries the
page title. The masthead copy around the `<h1>` is neutral ("Archive",
"Index") because the theme ships inside the `archive` starter; edit the
layout to name your own archive.
