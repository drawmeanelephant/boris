# Boris (default)

The product default. Orange accent, sticky rail, slightly-too-large type.
That oddness is the point — do not sand it into another calm docs skin.

- Layouts: `main.html`
- Assets: `assets/css/boris.css` (system UI stack; no webfont)
- Footer: `footer.html`
- Search: first-party inline consumer; nav remains the no-JS path
- Slots: title, head, nav, breadcrumb, toc, metadata, content, children, relations, backlinks, footer, asset-url
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

```bash
./zig-out/bin/boris --theme themes/boris --html-dir dist --quiet
```

## Intentionally absent slots

- `{{tags}}` — `{{metadata}}` already prints Tags in the page header. A second
  per-tag list would repeat it on every tagged page.
- `{{parent}}` — `{{breadcrumb}}` sits directly above `main` and already links
  the parent.
- `{{page-status}}` — `{{metadata}}` prints Status as text. The product default
  does not add a draft badge on top of that.
