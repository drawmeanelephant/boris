# Corporate

Dense product-docs chrome. Graph nav is real. Search is the first-party
inline consumer. There are no `#` links or dead icon buttons. See
[`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `main.html`
- Specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/corporate \
  --html-dir test-output/corporate \
  --quiet
```

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Directly inside `<head>` (already present). |
| `{{relations}}` / `{{backlinks}}` | After the children list (already present), now as two bordered cards, "Related articles" / "Referenced by", inside a `data-boris-search-exclude` wrapper. Pages with no relations emit nothing. |
| `{{tags}}` | Intentionally absent. The metadata line lists tags, and this theme also backs CV-style pages where tag chips would be noise. |
| `{{parent}}` | Intentionally absent. `{{breadcrumb}}` opens the content column and already links the parent. |
| `{{page-status}}` | Intentionally absent. The metadata line states the status in text; product docs here have no badge row to carry it. |

## Print

`@media print` is a clean single-column document suitable for a CV: the
header, search, navigation, outline, breadcrumb, metadata, children,
relations, and footer are removed; type is set in points; headings avoid
breaking from their first line; lists keep their bullets; external links
print their URL after the link text.
