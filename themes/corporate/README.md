# Corporate

Dense product-docs chrome. Graph nav is real. Search is the first-party
inline consumer. There are no `#` links or dead icon buttons. See
[`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `main.html`
- Specimen: [`examples/studies-site/`](../../examples/studies-site/) (docs);
  `boris init --type resume` (print, see [Print](#print))

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

## Named layouts

Single shape by design. Product-docs chrome has one page shape, and
`@media print` on `main.html` is the print shape. A separate `print.html`
would fork the chrome and add no new shape: the CV prints from the same
page a reader browses. As the `landing` alternate, corporate renders the
landing page through `main.html`. The `home` shapes for a landing page are
in `service` and `civic`.

## Print

`@media print` is a clean single-column document suitable for a CV: the
header, search, navigation, outline, breadcrumb, metadata, children,
relations, and footer are removed; type is set in points; headings avoid
breaking from their first line; lists keep their bullets; body links stay
underlined in black, and external links print their URL after the link
text.

Print specimen: the `boris init --type resume` tree. Verified on
2026-10-10 by building that tree with this theme and printing `index.html`
with headless Chrome (`--print-to-pdf --no-pdf-header-footer`). The result
is one Letter page, a single column on white. No breadcrumb, children list,
footer, or surface tint prints, and the internal "Now" link is underlined.
