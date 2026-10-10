# Journal

Phosphor terminal diary. Native disclosure only. No JavaScript. See
[`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `main.html`
- Assets: `assets/journal.css` (Courier New system stack)
- Sample site: [`examples/journal-site/`](../../examples/journal-site/)

```bash
./zig-out/bin/boris \
  --input examples/journal-site/content \
  --theme themes/journal \
  --html-dir test-output/journal \
  --quiet
```

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Directly inside `<head>`. |
| `{{relations}}` / `{{backlinks}}` | After the entry, as a terminal block (`$ links --out` / `$ links --in`) that prints the raw kind token in brackets. The wrapper is `data-boris-search-exclude`. Pages with no relations emit nothing. |
| `{{tags}}` | In the entry header, as `tags: #a #b`; the duplicate Tags entry in the metadata line is hidden. A diary is browsed by tag. |
| `{{page-status}}` | As `<body data-status="…">`. Draft entries show the Status entry in inverse video; archived entries get a dashed box. |
| `{{parent}}` | Intentionally absent. `{{breadcrumb}}` sits directly above every entry and already links the parent. |
