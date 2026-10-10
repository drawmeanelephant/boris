# Journal

Phosphor terminal diary. Native disclosure only. No JavaScript. See
[`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `main.html` (one dated entry), `archive.html` (the log index)
- Assets: `assets/journal.css` (Courier New system stack)
- Sample site: [`examples/journal-site/`](../../examples/journal-site/)

```bash
./zig-out/bin/boris \
  --input examples/journal-site/content \
  --theme themes/journal \
  --layout-rule default id:index themes/journal/layouts/archive.html \
  --html-dir test-output/journal \
  --quiet
```

## Named layouts

A diary has two page shapes: the entry and the list of entries.

- `main.html` is the entry: a boxed `DOCUMENT ENTRY` with userpic, metadata
  line, and the children panel as a footnote. It is the fallback for every
  page.
- `archive.html` is the log index for the page whose satellites are the
  dated entries. The intro prose sits above an `$ ls entries/` listing of
  `{{children}}`, with no entry box or userpic. The listing is in canonical
  id order, so number or date your entry ids (`001-first-boot`,
  `2026-08-03-…`) when order matters. Select it for the parent of the
  entries: `id:index` for this sample site, `id:changes` for the
  `changelog` starter tree.

`home`, `section`, `blog`, and `print` are declined. `archive.html` already
serves the front page of a one-log diary, a diary has no section level
between the log and the entry, `main.html` is already the dated-entry
(blog) shape, and `@media print` turns either layout into black on white.

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Directly inside `<head>`. Both layouts carry the same slots. |
| `{{children}}` | `main`: an "Archive entries" panel after the entry. `archive`: the `$ ls entries/` listing, the body of the page. Both are `data-boris-search-exclude` and hide when the page has no children. |
| `{{relations}}` / `{{backlinks}}` | After the entry, as a terminal block (`$ links --out` / `$ links --in`) that prints the raw kind token in brackets. The wrapper is `data-boris-search-exclude`. Pages with no relations emit nothing. |
| `{{tags}}` | In the entry header, as `tags: #a #b`; the duplicate Tags entry in the metadata line is hidden. A diary is browsed by tag. |
| `{{page-status}}` | As `<body data-status="…">`. Draft entries show the Status entry in inverse video; archived entries get a dashed box. |
| `{{parent}}` | Intentionally absent. `{{breadcrumb}}` sits directly above every entry and already links the parent. |
